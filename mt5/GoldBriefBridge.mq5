//+------------------------------------------------------------------+
//| GoldBriefBridge.mq5                                              |
//| Places the Gold Brief plan as a pending order when you tap       |
//| "Follow plan" in the Gold Brief Android app.                     |
//|                                                                  |
//| Flow: app writes orders/req-<id>.json to GitHub (branch          |
//| cyd-orders) -> this EA polls, validates, places the pending      |
//| order(s) with SL/TP -> writes orders/status-<id>.json back.      |
//|                                                                  |
//| Setup: Tools > Options > Expert Advisors > Allow WebRequest for  |
//|   https://api.github.com                                         |
//| Attach to any chart (one instance only). Needs Algo Trading ON.  |
//+------------------------------------------------------------------+
#property copyright "mastersurat"
#property version   "1.00"
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

CTrade trade;

struct Entry { string name; string sha; };
string g_doneIds[];           // ids already handled in this run (status written or attempted)
string g_trackIds[];          // ids we placed and still watch (PLACED -> FILLED / EXPIRED)
string g_lastErr = "";

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
string ApiUrl(const string path) { return "https://api.github.com/repos/" + InpRepo + "/contents/" + path + "?ref=" + InpBranch; }

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
string FindSha(Entry &list[], const string name) { for(int i = 0; i < ArraySize(list); i++) if(list[i].name == name) return list[i].sha; return ""; }

bool WriteStatus(Entry &list[], const string id, const string state, const string tickets, double lot, const string detail) {
   string js = "{\"id\":\"" + JEsc(id) + "\",\"state\":\"" + state + "\",\"tickets\":\"" + tickets +
               "\",\"lot\":" + DoubleToString(lot, 2) + ",\"detail\":\"" + JEsc(detail) +
               "\",\"account\":\"" + (AccountInfoInteger(ACCOUNT_TRADE_MODE) == ACCOUNT_TRADE_MODE_DEMO ? "DEMO" : "REAL") +
               "\",\"time\":\"" + IsoNowBkk() + "\"}";
   uchar raw[], b64[], key[];
   int len = StringToCharArray(js, raw, 0, WHOLE_ARRAY, CP_UTF8);
   ArrayResize(raw, len - 1);
   CryptEncode(CRYPT_BASE64, raw, key, b64);
   string content = CharArrayToString(b64);
   string name = "status-" + id + ".json";
   string sha = FindSha(list, name);
   string body = "{\"message\":\"status " + id + " " + state + "\",\"branch\":\"" + InpBranch + "\",\"content\":\"" + content + "\"" +
                 (sha != "" ? ",\"sha\":\"" + sha + "\"" : "") + "}";
   string resp;
   int code = Http("PUT", ApiUrl("orders/" + name), body, "application/vnd.github+json", resp);
   if(code == 200 || code == 201) {
      string newSha = JStr(resp, "sha", StringFind(resp, "\"content\""));
      bool found = false;
      for(int i = 0; i < ArraySize(list); i++) if(list[i].name == name) { list[i].sha = newSha; found = true; }
      if(!found) { int n = ArraySize(list); ArrayResize(list, n + 1); list[n].name = name; list[n].sha = newSha; }
      PrintFormat("GoldBrief: %s -> %s %s %s", id, state, tickets, detail);
      return true;
   }
   PrintFormat("GoldBrief: status write failed for %s (HTTP %d) %s", id, code, StringSubstr(resp, 0, 200));
   return false;
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
   double lot = 0;
   if(lotMode == "RISK") {
      if(riskPct <= 0 || riskPct > InpMaxRiskPct) { WriteStatus(list, id, "REJECTED", "", 0, StringFormat("Risk %.2f%% outside 0-%.2f%%", riskPct, InpMaxRiskPct)); return; }
      double tickSize = SymbolInfoDouble(InpSymbol, SYMBOL_TRADE_TICK_SIZE);
      double tickVal  = SymbolInfoDouble(InpSymbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
      if(tickVal <= 0) tickVal = SymbolInfoDouble(InpSymbol, SYMBOL_TRADE_TICK_VALUE);
      double lossPerLot = MathAbs(entry - sl) / tickSize * tickVal;
      double money = AccountInfoDouble(ACCOUNT_BALANCE) * riskPct / 100.0;
      lot = lossPerLot > 0 ? money / lossPerLot : 0;
   } else lot = lotReq;
   if(lot > InpMaxLot) lot = InpMaxLot;
   lot = NormLot(lot);
   if(lot <= 0) { WriteStatus(list, id, "REJECTED", "", 0, "Lot below broker minimum"); return; }

   // --- split into parts
   double lots[]; double tps[];
   if(tpMode == "SPLIT" && tp2 > 0) {
      double half = NormLot(lot / 2.0);
      if(half > 0) {
         ArrayResize(lots, 2); ArrayResize(tps, 2);
         lots[0] = half; tps[0] = tp1;
         lots[1] = NormLot(lot - half); tps[1] = tp2;
         if(lots[1] <= 0) { ArrayResize(lots, 1); ArrayResize(tps, 1); }
      } else { ArrayResize(lots, 1); ArrayResize(tps, 1); lots[0] = lot; tps[0] = tp1; }
   } else {
      ArrayResize(lots, 1); ArrayResize(tps, 1);
      lots[0] = lot; tps[0] = (tpMode == "TP2" && tp2 > 0) ? tp2 : tp1;
   }

   // --- expiry: broker-side if supported, otherwise this EA deletes it later
   datetime expGmt = ExpiryGmt(date);
   datetime expServer = expGmt + (TimeTradeServer() - TimeGMT());
   int expModes = (int)SymbolInfoInteger(InpSymbol, SYMBOL_EXPIRATION_MODE);
   ENUM_ORDER_TYPE_TIME tt = (expModes & SYMBOL_EXPIRATION_SPECIFIED) ? ORDER_TIME_SPECIFIED : ORDER_TIME_GTC;

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
   Comment(StringFormat("GoldBriefBridge  %s  %s\nlast poll %s BKK  watching %d",
                        AccountInfoInteger(ACCOUNT_TRADE_MODE) == ACCOUNT_TRADE_MODE_DEMO ? "DEMO" : (InpAllowLive ? "REAL (allowed)" : "REAL (blocked)"),
                        InpSymbol, TimeToString(TimeGMT() + 7 * 3600, TIME_SECONDS), ArraySize(g_trackIds)));
}

int OnInit() {
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(50);
   if(!SymbolSelect(InpSymbol, true)) { Alert("GoldBriefBridge: symbol ", InpSymbol, " not found"); return INIT_PARAMETERS_INCORRECT; }
   EventSetTimer(MathMax(5, InpPollSec));
   Poll();
   return INIT_SUCCEEDED;
}
void OnDeinit(const int reason) { EventKillTimer(); Comment(""); }
void OnTimer() { Poll(); }
void OnTick() {}
