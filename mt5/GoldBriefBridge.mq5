//+------------------------------------------------------------------+
//| GoldBriefBridge.mq5                                              |
//| Places the Gold Brief plan as a pending order when you tap       |
//| "Follow plan" in the Gold Brief Android app.                     |
//|                                                                  |
//| Flow: app writes orders/req-<id>.json to GitHub (branch          |
//| cyd-orders) -> this EA polls, validates, places the pending      |
//| order(s) with SL/TP -> writes orders/status-<id>.json back.      |
//|                                                                  |
//| Auto mode (v1.10): when switched on in the app (orders/auto.json)|
//| the EA reads the live brief, picks the best of plan A/B and opens |
//| a market order when price reaches that plan's entry. Status goes  |
//| to orders/auto-status.json.                                       |
//|                                                                  |
//| Setup: Tools > Options > Expert Advisors > Allow WebRequest for  |
//|   https://api.github.com                                         |
//| Attach to any chart (one instance only). Needs Algo Trading ON.  |
//+------------------------------------------------------------------+
#property copyright "mastersurat"
#property version   "1.10"
#property strict

#include <Trade/Trade.mqh>

input string InpToken      = "";                     // GitHub token (Contents read/write on the repo)
input string InpRepo       = "mastersurat/master-iot";
input string InpBranch     = "cyd-orders";
input string InpSymbol     = "XAUUSDm";              // symbol to trade
input long   InpMagic      = 28102026;
input double InpMaxLot     = 0.10;                   // hard cap per request (all parts together)
input double InpMaxRiskPct = 2.0;                    // hard cap for risk-% requests
input int    InpPollSec    = 10;
input bool   InpAllowLive  = false;                  // refuse to trade a REAL account unless true
input int    InpExpireHour = 6;                      // pending orders expire next day at this hour (Bangkok)
input int    InpExpireMin  = 30;
input bool   InpAutoAllowed   = true;               // let the app switch on auto mode
input double InpAutoMaxSlip   = 3.0;                // auto: never open further than this past entry (USD)
input double InpAutoMaxSpread = 1.0;                // auto: wait while spread is wider than this (USD)
input string InpBriefBranch   = "cyd-brief";        // where brief.json lives

CTrade trade;

struct Entry { string name; string sha; };
string g_doneIds[];           // ids already handled in this run (status written or attempted)
string g_trackIds[];          // ids we placed and still watch (PLACED -> FILLED / EXPIRED)
string g_lastErr = "";
#define EA_VER "1.10"

// ---- auto mode state
string   g_autoSha = "";                // sha of orders/auto.json last read ("" = none)
bool     g_autoOn = false;
string   g_autoLotMode = "FIXED", g_autoTp = "SPLIT";
double   g_autoLot = 0.01, g_autoRisk = 0.5, g_autoSlip = 2.0;
string   g_briefGen = "", g_briefDate = "", g_briefBias = "";
int      g_briefRev = 0;
string   g_plans[];                     // plan objects of the live brief (raw JSON)
datetime g_lastBriefFetch = 0;
string   g_excluded[];                  // plan keys ruled out for this revision (missed / invalid)
string   g_selKey = "", g_selId = "", g_selSide = "", g_selType = "", g_selReason = "";
double   g_selEntry = 0, g_selSl = 0, g_selTp1 = 0, g_selTp2 = 0, g_selScore = 0;
string   g_autoState = "OFF", g_autoDetail = "", g_autoTickets = "";
string   g_openedGen = "";              // brief revision in which auto already opened a trade
string   g_autoStatusSig = "";
datetime g_lastHeartbeat = 0;

//------------------------------------------------------------------ helpers
string BkkDate(datetime gmt) {
   string d = TimeToString(gmt + 7 * 3600, TIME_DATE);   // "2026.10.28"
   StringReplace(d, ".", "-");
   return d;
}
string IsoNowBkk() {
   string s = TimeToString(TimeGMT() + 7 * 3600, TIME_DATE | TIME_SECONDS);
   StringReplace(s, ".", "-");
   StringReplace(s, " ", "T");
   return s + "+07:00";
}
bool InList(string &arr[], string v) { for(int i = 0; i < ArraySize(arr); i++) if(arr[i] == v) return true; return false; }
void AddList(string &arr[], string v) { if(InList(arr, v)) return; int n = ArraySize(arr); ArrayResize(arr, n + 1); arr[n] = v; }
void RemoveList(string &arr[], string v) {
   int n = ArraySize(arr);
   for(int i = 0; i < n; i++) if(arr[i] == v) { arr[i] = arr[n - 1]; ArrayResize(arr, n - 1); return; }
}

// minimal JSON field reader for flat objects: returns raw value text (no quotes)
string JStr(const string js, const string key, int from = 0) {
   int k = StringFind(js, "\"" + key + "\"", from);
   if(k < 0) return "";
   int c = StringFind(js, ":", k + StringLen(key) + 2);
   if(c < 0) return "";
   int i = c + 1, n = StringLen(js);
   while(i < n && (StringGetCharacter(js, i) == ' ' || StringGetCharacter(js, i) == '\n' || StringGetCharacter(js, i) == '\r' || StringGetCharacter(js, i) == '\t')) i++;
   if(i >= n) return "";
   if(StringGetCharacter(js, i) == '"') {
      string out = "";
      for(int j = i + 1; j < n; j++) {
         ushort ch = StringGetCharacter(js, j);
         if(ch == '\\' && j + 1 < n) { out += ShortToString(StringGetCharacter(js, j + 1)); j++; continue; }
         if(ch == '"') return out;
         out += ShortToString(ch);
      }
      return out;
   }
   int j = i;
   while(j < n) { ushort ch = StringGetCharacter(js, j); if(ch == ',' || ch == '}' || ch == ']' || ch == '\n') break; j++; }
   string v = StringSubstr(js, i, j - i);
   StringTrimLeft(v); StringTrimRight(v);
   return v;
}
double JNum(const string js, const string key) { return StringToDouble(JStr(js, key)); }
string JEsc(string s) { StringReplace(s, "\\", "\\\\"); StringReplace(s, "\"", "\\\""); return s; }

//------------------------------------------------------------------ GitHub API
int Http(const string method, const string url, const string body, const string accept, string &resp) {
   string hdr = "Authorization: Bearer " + InpToken + "\r\n" +
                "Accept: " + accept + "\r\n" +
                "User-Agent: GoldBriefBridge-MT5\r\n" +
                "X-GitHub-Api-Version: 2022-11-28\r\n";
   char data[], res[];
   if(body != "") {
      hdr += "Content-Type: application/json\r\n";
      int len = StringToCharArray(body, data, 0, WHOLE_ARRAY, CP_UTF8);
      ArrayResize(data, MathMax(0, len - 1));           // drop trailing \0
   }
   string rh;
   ResetLastError();
   int code = WebRequest(method, url, hdr, 10000, data, res, rh);
   if(code == -1) {
      int e = GetLastError();
      g_lastErr = (e == 4014) ? "WebRequest not allowed: add https://api.github.com in Tools>Options>Expert Advisors"
                              : "WebRequest error " + IntegerToString(e);
      resp = "";
      return -1;
   }
   resp = CharArrayToString(res, 0, WHOLE_ARRAY, CP_UTF8);
   return code;
}
string ApiUrlRef(const string path, const string ref) { return "https://api.github.com/repos/" + InpRepo + "/contents/" + path + "?ref=" + ref; }
string ApiUrl(const string path) { return ApiUrlRef(path, InpBranch); }

int ListOrders(Entry &out[]) {
   string resp;
   int code = Http("GET", ApiUrl("orders"), "", "application/vnd.github+json", resp);
   ArrayResize(out, 0);
   if(code != 200) { if(code > 0) g_lastErr = "list HTTP " + IntegerToString(code); return code; }
   int pos = 0;
   while(true) {
      int k = StringFind(resp, "\"name\"", pos);
      if(k < 0) break;
      string name = JStr(resp, "name", k);
      int s = StringFind(resp, "\"sha\"", k);
      string sha = s >= 0 ? JStr(resp, "sha", s) : "";
      int n = ArraySize(out); ArrayResize(out, n + 1);
      out[n].name = name; out[n].sha = sha;
      pos = (s > k ? s : k) + 5;
   }
   return code;
}
string ReadFile(const string path) {
   string resp;
   int code = Http("GET", ApiUrl(path), "", "application/vnd.github.raw", resp);
   return code == 200 ? resp : "";
}
string ReadFileRef(const string path, const string ref) {
   string resp;
   int code = Http("GET", ApiUrlRef(path, ref), "", "application/vnd.github.raw", resp);
   return code == 200 ? resp : "";
}
string FindSha(Entry &list[], const string name) { for(int i = 0; i < ArraySize(list); i++) if(list[i].name == name) return list[i].sha; return ""; }

bool PutFile(Entry &list[], const string name, const string js, const string msg) {
   uchar raw[], b64[], key[];
   int len = StringToCharArray(js, raw, 0, WHOLE_ARRAY, CP_UTF8);
   ArrayResize(raw, len - 1);
   CryptEncode(CRYPT_BASE64, raw, key, b64);
   string content = CharArrayToString(b64);
   string sha = FindSha(list, name);
   string body = "{\"message\":\"" + JEsc(msg) + "\",\"branch\":\"" + InpBranch + "\",\"content\":\"" + content + "\"" +
                 (sha != "" ? ",\"sha\":\"" + sha + "\"" : "") + "}";
   string resp;
   int code = Http("PUT", ApiUrl("orders/" + name), body, "application/vnd.github+json", resp);
   if(code == 200 || code == 201) {
      string newSha = JStr(resp, "sha", StringFind(resp, "\"content\""));
      bool found = false;
      for(int i = 0; i < ArraySize(list); i++) if(list[i].name == name) { list[i].sha = newSha; found = true; }
      if(!found) { int n = ArraySize(list); ArrayResize(list, n + 1); list[n].name = name; list[n].sha = newSha; }
      return true;
   }
   PrintFormat("GoldBrief: write %s failed (HTTP %d) %s", name, code, StringSubstr(resp, 0, 200));
   return false;
}
string AccountKind() { return AccountInfoInteger(ACCOUNT_TRADE_MODE) == ACCOUNT_TRADE_MODE_DEMO ? "DEMO" : "REAL"; }

bool WriteStatus(Entry &list[], const string id, const string state, const string tickets, double lot, const string detail) {
   string js = "{\"id\":\"" + JEsc(id) + "\",\"state\":\"" + state + "\",\"tickets\":\"" + tickets +
               "\",\"lot\":" + DoubleToString(lot, 2) + ",\"detail\":\"" + JEsc(detail) +
               "\",\"account\":\"" + AccountKind() + "\",\"time\":\"" + IsoNowBkk() + "\"}";
   bool ok = PutFile(list, "status-" + id + ".json", js, "status " + id + " " + state);
   if(ok) PrintFormat("GoldBrief: %s -> %s %s %s", id, state, tickets, detail);
   return ok;
}

//------------------------------------------------------------------ trading
string CommentFor(const string id, int part) { return "GB " + id + (part > 0 ? "/" + IntegerToString(part) : ""); }

bool HasOurOrders(const string id, string &tickets) {
   tickets = "";
   string tag = "GB " + id;
   for(int i = OrdersTotal() - 1; i >= 0; i--) {
      ulong t = OrderGetTicket(i);
      if(OrderGetInteger(ORDER_MAGIC) == InpMagic && StringFind(OrderGetString(ORDER_COMMENT), tag) == 0)
         tickets += (tickets == "" ? "" : ",") + (string)t;
   }
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong t = PositionGetTicket(i);
      if(PositionGetInteger(POSITION_MAGIC) == InpMagic && StringFind(PositionGetString(POSITION_COMMENT), tag) == 0)
         tickets += (tickets == "" ? "" : ",") + (string)t;
   }
   return tickets != "";
}
int CountPending(const string id) {
   int n = 0; string tag = "GB " + id;
   for(int i = OrdersTotal() - 1; i >= 0; i--) {
      OrderGetTicket(i);
      if(OrderGetInteger(ORDER_MAGIC) == InpMagic && StringFind(OrderGetString(ORDER_COMMENT), tag) == 0) n++;
   }
   return n;
}
int CountPositions(const string id) {
   int n = 0; string tag = "GB " + id;
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      PositionGetTicket(i);
      if(PositionGetInteger(POSITION_MAGIC) == InpMagic && StringFind(PositionGetString(POSITION_COMMENT), tag) == 0) n++;
   }
   return n;
}
int DeletePending(const string id) {
   int n = 0; string tag = "GB " + id;
   for(int i = OrdersTotal() - 1; i >= 0; i--) {
      ulong t = OrderGetTicket(i);
      if(OrderGetInteger(ORDER_MAGIC) == InpMagic && StringFind(OrderGetString(ORDER_COMMENT), tag) == 0)
         if(trade.OrderDelete(t)) n++;
   }
   return n;
}

double NormLot(double lot) {
   double step = SymbolInfoDouble(InpSymbol, SYMBOL_VOLUME_STEP);
   double mn   = SymbolInfoDouble(InpSymbol, SYMBOL_VOLUME_MIN);
   double mx   = SymbolInfoDouble(InpSymbol, SYMBOL_VOLUME_MAX);
   if(step <= 0) step = 0.01;
   lot = MathFloor(lot / step + 1e-9) * step;
   if(lot < mn) return 0;
   return NormalizeDouble(MathMin(lot, mx), 2);
}

// lot from a fixed size or a risk %, capped by the EA inputs; 0 with a reason when not possible
double CalcLot(const string lotMode, double lotReq, double riskPct, double entry, double sl, string &err) {
   err = "";
   double lot = 0;
   if(lotMode == "RISK") {
      if(riskPct <= 0 || riskPct > InpMaxRiskPct) { err = StringFormat("Risk %.2f%% outside 0-%.2f%%", riskPct, InpMaxRiskPct); return 0; }
      double tickSize = SymbolInfoDouble(InpSymbol, SYMBOL_TRADE_TICK_SIZE);
      double tickVal  = SymbolInfoDouble(InpSymbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
      if(tickVal <= 0) tickVal = SymbolInfoDouble(InpSymbol, SYMBOL_TRADE_TICK_VALUE);
      double lossPerLot = tickSize > 0 ? MathAbs(entry - sl) / tickSize * tickVal : 0;
      double money = AccountInfoDouble(ACCOUNT_BALANCE) * riskPct / 100.0;
      lot = lossPerLot > 0 ? money / lossPerLot : 0;
   } else lot = lotReq;
   if(lot > InpMaxLot) lot = InpMaxLot;
   lot = NormLot(lot);
   if(lot <= 0) err = "Lot below broker minimum";
   return lot;
}

void SplitParts(double lot, const string tpMode, double tp1, double tp2, double &lots[], double &tps[]) {
   if(tpMode == "SPLIT" && tp2 > 0) {
      double half = NormLot(lot / 2.0);
      if(half > 0) {
         ArrayResize(lots, 2); ArrayResize(tps, 2);
         lots[0] = half; tps[0] = tp1;
         lots[1] = NormLot(lot - half); tps[1] = tp2;
         if(lots[1] <= 0) { ArrayResize(lots, 1); ArrayResize(tps, 1); }
         return;
      }
      ArrayResize(lots, 1); ArrayResize(tps, 1); lots[0] = lot; tps[0] = tp1;
      return;
   }
   ArrayResize(lots, 1); ArrayResize(tps, 1);
   lots[0] = lot; tps[0] = (tpMode == "TP2" && tp2 > 0) ? tp2 : tp1;
}

// Bangkok "next day hh:mm" after the request date, as GMT
datetime ExpiryGmt(const string date) {
   string d = date; StringReplace(d, "-", ".");
   datetime bkkMidnight = StringToTime(d);                   // treated as BKK wall time
   datetime bkk = bkkMidnight + 86400 + InpExpireHour * 3600 + InpExpireMin * 60;
   return bkk - 7 * 3600;
}

void ProcessRequest(Entry &list[], const string id) {
   string js = ReadFile("orders/req-" + id + ".json");
   if(js == "") return;                                     // try again next poll
   AddList(g_doneIds, id);

   string date = JStr(js, "date"), side = JStr(js, "side"), type = JStr(js, "type");
   string tpMode = JStr(js, "tp_mode"), lotMode = JStr(js, "lot_mode");
   double entry = JNum(js, "entry"), sl = JNum(js, "sl"), tp1 = JNum(js, "tp1"), tp2 = JNum(js, "tp2");
   double lotReq = JNum(js, "lot"), riskPct = JNum(js, "risk_pct");
   int digits = (int)SymbolInfoInteger(InpSymbol, SYMBOL_DIGITS);

   // --- guards
   if(AccountInfoInteger(ACCOUNT_TRADE_MODE) != ACCOUNT_TRADE_MODE_DEMO && !InpAllowLive) { WriteStatus(list, id, "REJECTED", "", 0, "Real account: EA is set to demo only"); return; }
   if(TimeGMT() > ExpiryGmt(date))   { WriteStatus(list, id, "REJECTED", "", 0, "Request expired (plan date " + date + ")"); return; }
   if(!SymbolSelect(InpSymbol, true)) { WriteStatus(list, id, "REJECTED", "", 0, "Symbol " + InpSymbol + " not available"); return; }
   bool sell = side == "SELL";
   if(!(side == "SELL" || side == "BUY") || !(type == "LIMIT" || type == "STOP") || entry <= 0 || sl <= 0 || tp1 <= 0) {
      WriteStatus(list, id, "REJECTED", "", 0, "Bad request fields"); return;
   }
   if(sell ? !(sl > entry && tp1 < entry) : !(sl < entry && tp1 > entry)) { WriteStatus(list, id, "REJECTED", "", 0, "SL/TP on wrong side of entry"); return; }
   string existing;
   if(HasOurOrders(id, existing)) { WriteStatus(list, id, "PLACED", existing, 0, "Already placed"); AddList(g_trackIds, id); return; }

   MqlTick tk; SymbolInfoTick(InpSymbol, tk);
   double ref = sell ? tk.bid : tk.ask;
   bool okSide = sell ? (type == "LIMIT" ? entry > ref : entry < ref) : (type == "LIMIT" ? entry < ref : entry > ref);
   if(!okSide) {
      WriteStatus(list, id, "REJECTED", "", 0, StringFormat("Price %.2f already past entry %.2f for %s %s", ref, entry, side, type)); return;
   }

   // --- volume
   string lotErr;
   double lot = CalcLot(lotMode, lotReq, riskPct, entry, sl, lotErr);
   if(lot <= 0) { WriteStatus(list, id, "REJECTED", "", 0, lotErr); return; }

   // --- split into parts
   double lots[]; double tps[];
   SplitParts(lot, tpMode, tp1, tp2, lots, tps);

   // --- expiry: broker-side if supported, otherwise this EA deletes it later
   datetime expGmt = ExpiryGmt(date);
   datetime expServer = expGmt + (TimeTradeServer() - TimeGMT());
   int expModes = (int)SymbolInfoInteger(InpSymbol, SYMBOL_EXPIRATION_MODE);
   ENUM_ORDER_TYPE_TIME tt = ((expModes & SYMBOL_EXPIRATION_SPECIFIED) != 0) ? ORDER_TIME_SPECIFIED : ORDER_TIME_GTC;

   string tickets = ""; double total = 0; string errs = "";
   for(int i = 0; i < ArraySize(lots); i++) {
      double e = NormalizeDouble(entry, digits), s = NormalizeDouble(sl, digits), t = NormalizeDouble(tps[i], digits);
      string cm = CommentFor(id, ArraySize(lots) > 1 ? i + 1 : 0);
      bool ok;
      if(sell) ok = type == "LIMIT" ? trade.SellLimit(lots[i], e, InpSymbol, s, t, tt, tt == ORDER_TIME_SPECIFIED ? expServer : 0, cm)
                                    : trade.SellStop (lots[i], e, InpSymbol, s, t, tt, tt == ORDER_TIME_SPECIFIED ? expServer : 0, cm);
      else     ok = type == "LIMIT" ? trade.BuyLimit (lots[i], e, InpSymbol, s, t, tt, tt == ORDER_TIME_SPECIFIED ? expServer : 0, cm)
                                    : trade.BuyStop  (lots[i], e, InpSymbol, s, t, tt, tt == ORDER_TIME_SPECIFIED ? expServer : 0, cm);
      if(ok && trade.ResultRetcode() == TRADE_RETCODE_DONE) {
         tickets += (tickets == "" ? "" : ",") + (string)trade.ResultOrder();
         total += lots[i];
      } else errs += (errs == "" ? "" : "; ") + trade.ResultRetcodeDescription();
   }
   if(tickets == "") { WriteStatus(list, id, "REJECTED", "", 0, "Broker: " + errs); return; }
   string detail = StringFormat("%s %s %.2f @ %.2f SL %.2f TP %s", side, type, total, entry, sl,
                                ArraySize(tps) > 1 ? DoubleToString(tps[0], 2) + "/" + DoubleToString(tps[1], 2) : DoubleToString(tps[0], 2));
   if(errs != "") detail += " (part failed: " + errs + ")";
   WriteStatus(list, id, "PLACED", tickets, total, detail);
   AddList(g_trackIds, id);
}

void ProcessCancel(Entry &list[], const string id) {
   AddList(g_doneIds, "cancel-" + id);
   int n = DeletePending(id);
   int open = CountPositions(id);
   string detail = StringFormat("Deleted %d pending order(s)", n);
   if(open > 0) detail += StringFormat("; %d position(s) already open - manage in MT5", open);
   WriteStatus(list, id, "CANCELLED", "", 0, detail);
   RemoveList(g_trackIds, id);
}

// pending -> FILLED, and our own expiry when the broker has no specified-time support
void TrackPlaced(Entry &list[]) {
   for(int i = ArraySize(g_trackIds) - 1; i >= 0; i--) {
      string id = g_trackIds[i];
      string date = StringSubstr(id, 0, 10);
      int pend = CountPending(id), pos = CountPositions(id);
      if(pend > 0 && TimeGMT() > ExpiryGmt(date)) {
         DeletePending(id);
         WriteStatus(list, id, pos > 0 ? "FILLED" : "EXPIRED", "", 0, pos > 0 ? "Part filled; rest expired" : "Not triggered before expiry");
         RemoveList(g_trackIds, id);
      } else if(pend == 0) {
         string tk;
         HasOurOrders(id, tk);
         WriteStatus(list, id, pos > 0 ? "FILLED" : "CLOSED", tk, 0, pos > 0 ? "Order triggered - position open" : "No pending order left (filled and closed, expired or removed)");
         RemoveList(g_trackIds, id);
      }
   }
}


//------------------------------------------------------------------ auto mode
string AutoTag() { return "GB AUTO "; }
string PlanKeyOf(const string id) { return g_briefDate + "-" + (g_briefRev > 0 ? "R" + IntegerToString(g_briefRev) : "") + id; }

int CountAutoPositions() {
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      PositionGetTicket(i);
      if(PositionGetInteger(POSITION_MAGIC) == InpMagic && StringFind(PositionGetString(POSITION_COMMENT), AutoTag()) == 0) n++;
   }
   return n;
}

// the brief is the live plan: its date is today in Bangkok, or yesterday before the 06:30 expiry
bool BriefLive() {
   if(g_briefDate == "") return false;
   if(g_briefDate == BkkDate(TimeGMT())) return true;
   return g_briefDate == BkkDate(TimeGMT() - 86400) && TimeGMT() <= ExpiryGmt(g_briefDate);
}

void SplitPlans(const string js) {
   ArrayResize(g_plans, 0);
   int k = StringFind(js, "\"plans\"");
   if(k < 0) return;
   int a = StringFind(js, "[", k), end = StringFind(js, "]", a);
   if(a < 0 || end < 0) return;
   int pos = a;
   while(true) {
      int o = StringFind(js, "{", pos);
      if(o < 0 || o > end) break;
      int c = StringFind(js, "}", o);
      if(c < 0) break;
      int n = ArraySize(g_plans); ArrayResize(g_plans, n + 1);
      g_plans[n] = StringSubstr(js, o, c - o + 1);
      pos = c + 1;
   }
}

bool Reached(bool sell, const string type, double ref, double entry) {
   return sell ? (type == "LIMIT" ? ref >= entry : ref <= entry) : (type == "LIMIT" ? ref <= entry : ref >= entry);
}

// pick the best plan of this revision: reward:risk to TP1, +1 if it follows the bias, +0.25 for plan A
// (the primary setup), minus a little for distance; plans already past entry/SL are left out
void SelectBest() {
   g_selKey = ""; g_selId = ""; g_selReason = ""; g_selScore = -1e9;
   MqlTick tk; if(!SymbolInfoTick(InpSymbol, tk)) return;
   double slip = MathMin(g_autoSlip, InpAutoMaxSlip);
   for(int i = 0; i < ArraySize(g_plans); i++) {
      string pj = g_plans[i];
      string id = JStr(pj, "id"), side = JStr(pj, "side"), type = JStr(pj, "type");
      double entry = JNum(pj, "entry"), sl = JNum(pj, "sl"), tp1 = JNum(pj, "tp1"), tp2 = JNum(pj, "tp2");
      string key = PlanKeyOf(id);
      if(InList(g_excluded, key)) continue;
      bool sell = side == "SELL";
      double risk = MathAbs(entry - sl);
      if(risk <= 0 || !(sell ? (sl > entry && tp1 < entry) : (sl < entry && tp1 > entry))) continue;
      double ref = sell ? tk.bid : tk.ask;
      if(sell ? ref >= sl : ref <= sl) continue;                                   // already beyond SL
      double dist = MathAbs(ref - entry);
      if(Reached(sell, type, ref, entry) && dist > slip) continue;                 // already ran past entry
      bool aligned = (g_briefBias == "BEARISH" && sell) || (g_briefBias == "BULLISH" && !sell);
      double rr = MathAbs(tp1 - entry) / risk;
      double score = rr + (aligned ? 1.0 : 0.0) + (id == "A" ? 0.25 : 0.0) - 0.5 * MathMin(1.0, dist / (3.0 * risk));
      if(score > g_selScore) {
         g_selScore = score; g_selKey = key; g_selId = id; g_selSide = side; g_selType = type;
         g_selEntry = entry; g_selSl = sl; g_selTp1 = tp1; g_selTp2 = tp2;
         g_selReason = StringFormat("RR %.2f%s%s, %.1f away", rr, aligned ? ", follows " + g_briefBias : "", id == "A" ? ", primary plan" : "", dist);
      }
   }
   if(g_selKey == "") { g_autoState = "NONE"; g_autoDetail = "No plan is still valid for auto entry"; }
   else { g_autoState = "WAITING"; g_autoDetail = "Waiting for " + g_selSide + " " + g_selType + " " + DoubleToString(g_selEntry, 2); }
}

void RuleOut(const string why) {
   AddList(g_excluded, g_selKey);
   string was = "Plan " + g_selId + ": " + why;
   SelectBest();
   g_autoDetail = was + (g_selKey != "" ? " -> now plan " + g_selId : "");
}

// runs every second and on ticks: open the selected plan when price reaches its entry
void CheckAuto() {
   if(!g_autoOn || !InpAutoAllowed) return;
   if(g_selKey == "" || g_openedGen == g_briefGen) return;
   if(!BriefLive()) { g_autoState = "EXPIRED"; g_autoDetail = "Plan of " + g_briefDate + " expired"; g_selKey = ""; return; }
   MqlTick tk; if(!SymbolInfoTick(InpSymbol, tk)) return;
   bool sell = g_selSide == "SELL";
   double ref = sell ? tk.bid : tk.ask;
   if(sell ? ref >= g_selSl : ref <= g_selSl) { RuleOut("price went beyond SL before entry"); return; }
   if(!Reached(sell, g_selType, ref, g_selEntry)) return;
   double slip = MathMin(g_autoSlip, InpAutoMaxSlip);
   if(MathAbs(ref - g_selEntry) > slip) { RuleOut(StringFormat("price %.2f jumped %.2f past entry (max %.2f)", ref, MathAbs(ref - g_selEntry), slip)); return; }
   if(tk.ask - tk.bid > InpAutoMaxSpread) { g_autoDetail = StringFormat("Entry reached, waiting: spread %.2f > %.2f", tk.ask - tk.bid, InpAutoMaxSpread); return; }
   if(AccountInfoInteger(ACCOUNT_TRADE_MODE) != ACCOUNT_TRADE_MODE_DEMO && !InpAllowLive) { g_autoState = "BLOCKED"; g_autoDetail = "Real account: EA is set to demo only"; g_openedGen = g_briefGen; return; }
   if(CountAutoPositions() > 0) { g_autoDetail = "Entry reached, waiting: an earlier auto position is still open"; return; }
   string tks;
   if(HasOurOrders(g_selKey, tks)) { g_autoState = "SKIPPED"; g_autoDetail = "You already placed plan " + g_selId + " from the app (#" + tks + ")"; g_openedGen = g_briefGen; return; }

   string err;
   double lot = CalcLot(g_autoLotMode, g_autoLot, g_autoRisk, ref, g_selSl, err);
   if(lot <= 0) { g_autoState = "ERROR"; g_autoDetail = err; g_openedGen = g_briefGen; return; }
   double lots[], tps[];
   SplitParts(lot, g_autoTp, g_selTp1, g_selTp2, lots, tps);
   int digits = (int)SymbolInfoInteger(InpSymbol, SYMBOL_DIGITS);
   string tickets = "", errs = ""; double total = 0;
   for(int i = 0; i < ArraySize(lots); i++) {
      string cm = AutoTag() + g_selKey + (ArraySize(lots) > 1 ? "/" + IntegerToString(i + 1) : "");
      double s = NormalizeDouble(g_selSl, digits), t = NormalizeDouble(tps[i], digits);
      bool ok = sell ? trade.Sell(lots[i], InpSymbol, 0, s, t, cm) : trade.Buy(lots[i], InpSymbol, 0, s, t, cm);
      if(ok && (trade.ResultRetcode() == TRADE_RETCODE_DONE || trade.ResultRetcode() == TRADE_RETCODE_PLACED)) {
         tickets += (tickets == "" ? "" : ",") + (string)trade.ResultOrder(); total += lots[i];
      } else errs += (errs == "" ? "" : "; ") + trade.ResultRetcodeDescription();
   }
   g_openedGen = g_briefGen;
   g_autoTickets = tickets;
   if(tickets == "") { g_autoState = "ERROR"; g_autoDetail = "Broker: " + errs; return; }
   g_autoState = "OPENED";
   g_autoDetail = StringFormat("%s %.2f @ ~%.2f (plan %s, entry %.2f) SL %.2f TP %s", g_selSide, total, ref, g_selId, g_selEntry, g_selSl,
                               ArraySize(tps) > 1 ? DoubleToString(tps[0], 2) + "/" + DoubleToString(tps[1], 2) : DoubleToString(tps[0], 2));
   if(errs != "") g_autoDetail += " (part failed: " + errs + ")";
   PrintFormat("GoldBrief AUTO: %s %s", g_autoDetail, tickets);
}

// read orders/auto.json (switched from the app) and the live brief; publish auto-status.json
void PollAuto(Entry &list[]) {
   string sha = FindSha(list, "auto.json");
   if(sha != g_autoSha) {
      g_autoSha = sha;
      bool was = g_autoOn;
      if(sha == "") g_autoOn = false;
      else {
         string js = ReadFile("orders/auto.json");
         if(js == "") { g_autoSha = ""; return; }                    // retry next poll
         g_autoOn = JStr(js, "enabled") == "true";
         g_autoLotMode = JStr(js, "lot_mode") == "RISK" ? "RISK" : "FIXED";
         g_autoLot = JNum(js, "lot"); g_autoRisk = JNum(js, "risk_pct");
         string tp = JStr(js, "tp_mode"); g_autoTp = (tp == "TP1" || tp == "TP2") ? tp : "SPLIT";
         double sl = JNum(js, "max_slip"); g_autoSlip = sl > 0 ? sl : 2.0;
      }
      if(g_autoOn && !was) { ArrayResize(g_excluded, 0); g_lastBriefFetch = 0; }
      if(!g_autoOn) { g_autoState = InpAutoAllowed ? "OFF" : "DISABLED_IN_EA"; g_autoDetail = ""; g_selKey = ""; }
   }
   if(g_autoOn && TimeGMT() - g_lastBriefFetch >= 60) {
      g_lastBriefFetch = TimeGMT();
      string bj = ReadFileRef("brief.json", InpBriefBranch);
      string gen = JStr(bj, "generated");
      if(gen != "" && gen != g_briefGen) {
         g_briefGen = gen; g_briefDate = JStr(bj, "date"); g_briefRev = (int)StringToInteger(JStr(bj, "rev"));
         g_briefBias = JStr(bj, "bias");
         SplitPlans(bj);
         ArrayResize(g_excluded, 0);
         if(g_openedGen != g_briefGen) SelectBest();
      } else if(g_selKey == "" && g_autoState != "OPENED" && g_openedGen != g_briefGen && BriefLive()) SelectBest();
   }
   if(!InpAutoAllowed && g_autoOn) { g_autoState = "DISABLED_IN_EA"; g_autoDetail = "InpAutoAllowed is false in MT5"; }

   string sig = g_autoState + "|" + g_selKey + "|" + g_autoDetail + "|" + g_autoTickets + "|" + (g_autoOn ? "1" : "0");
   if(sig == g_autoStatusSig && TimeGMT() - g_lastHeartbeat < 15 * 60) return;
   string js = "{\"state\":\"" + g_autoState + "\",\"enabled\":" + (g_autoOn ? "true" : "false") +
               ",\"brief\":\"" + JEsc(g_briefGen) + "\",\"key\":\"" + JEsc(g_selKey) + "\",\"plan\":\"" + JEsc(g_selId) +
               "\",\"side\":\"" + g_selSide + "\",\"type\":\"" + g_selType + "\",\"entry\":" + DoubleToString(g_selEntry, 2) +
               ",\"sl\":" + DoubleToString(g_selSl, 2) + ",\"tp1\":" + DoubleToString(g_selTp1, 2) + ",\"tp2\":" + DoubleToString(g_selTp2, 2) +
               ",\"score\":" + DoubleToString(g_selScore > -1e8 ? g_selScore : 0, 2) + ",\"reason\":\"" + JEsc(g_selReason) +
               "\",\"detail\":\"" + JEsc(g_autoDetail) + "\",\"tickets\":\"" + g_autoTickets + "\",\"account\":\"" + AccountKind() +
               "\",\"ea\":\"" + EA_VER + "\",\"time\":\"" + IsoNowBkk() + "\"}";
   if(PutFile(list, "auto-status.json", js, "auto " + g_autoState + " " + g_selKey)) { g_autoStatusSig = sig; g_lastHeartbeat = TimeGMT(); }
}

void Poll() {
   if(InpToken == "") { Comment("GoldBriefBridge: set InpToken"); return; }
   Entry list[];
   int code = ListOrders(list);
   if(code != 200) { Comment("GoldBriefBridge: ", g_lastErr); return; }
   string today = BkkDate(TimeGMT()), yesterday = BkkDate(TimeGMT() - 86400);
   for(int i = 0; i < ArraySize(list); i++) {
      string name = list[i].name;
      if(StringFind(name, "req-") == 0) {
         string id = StringSubstr(name, 4, StringLen(name) - 9);        // req-<id>.json
         string d = StringSubstr(id, 0, 10);
         if(d != today && d != yesterday) continue;
         if(InList(g_doneIds, id)) continue;
         if(FindSha(list, "status-" + id + ".json") != "") {            // handled before (maybe by an earlier run)
            AddList(g_doneIds, id);
            string st = ReadFile("orders/status-" + id + ".json");
            string tk;
            if(JStr(st, "state") == "PLACED" && HasOurOrders(id, tk)) AddList(g_trackIds, id);
            continue;
         }
         ProcessRequest(list, id);
      } else if(StringFind(name, "cancel-") == 0) {
         string id = StringSubstr(name, 7, StringLen(name) - 12);       // cancel-<id>.json
         if(InList(g_doneIds, "cancel-" + id)) continue;
         string d = StringSubstr(id, 0, 10);
         if(d != today && d != yesterday) { AddList(g_doneIds, "cancel-" + id); continue; }
         string st = ReadFile("orders/status-" + id + ".json");
         if(JStr(st, "state") == "CANCELLED") { AddList(g_doneIds, "cancel-" + id); continue; }
         ProcessCancel(list, id);
      }
   }
   TrackPlaced(list);
   PollAuto(list);
   Comment(StringFormat("GoldBriefBridge %s  %s  %s\nlast poll %s BKK  watching %d\nAUTO %s %s %s",
                        EA_VER, AccountInfoInteger(ACCOUNT_TRADE_MODE) == ACCOUNT_TRADE_MODE_DEMO ? "DEMO" : (InpAllowLive ? "REAL (allowed)" : "REAL (blocked)"),
                        InpSymbol, TimeToString(TimeGMT() + 7 * 3600, TIME_SECONDS), ArraySize(g_trackIds),
                        g_autoState, g_selKey, g_autoDetail));
}

int OnInit() {
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(50);
   if(!SymbolSelect(InpSymbol, true)) { Alert("GoldBriefBridge: symbol ", InpSymbol, " not found"); return INIT_PARAMETERS_INCORRECT; }
   EventSetTimer(1);                                        // 1 s: auto entry check; GitHub every InpPollSec
   Poll();
   return INIT_SUCCEEDED;
}
void OnDeinit(const int reason) { EventKillTimer(); Comment(""); }
datetime g_lastPoll = 0;
void OnTimer() {
   CheckAuto();
   if(TimeLocal() - g_lastPoll >= MathMax(5, InpPollSec)) { g_lastPoll = TimeLocal(); Poll(); }
}
void OnTick() { CheckAuto(); }
