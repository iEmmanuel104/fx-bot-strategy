//+------------------------------------------------------------------+
//|                                      GoldEngulfingBot_v5_1.mq5   |
//|                                  Gold Engulfing Trading Strategy |
//|                                                       Version 5.1|
//|                    SIGNAL BROADCAST MODE - For Multi-Account Use |
//|  v5.1: Trade #2 SL uses 50% of engulfing body as minimum         |
//+------------------------------------------------------------------+
#property copyright "FXBot Trading"
#property link      "https://fxbot.trading"
#property version   "5.10"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\AccountInfo.mqh>

//+------------------------------------------------------------------+
//| Input Parameters                                                 |
//+------------------------------------------------------------------+
input group "=== Broadcast Mode (Multi-Account) ==="
input bool     BroadcastMode = true;                      // Enable Signal Broadcast Mode
input string   BroadcastURL = "https://fxbot-server-production.up.railway.app/api/signals/ea"; // Broadcast API Endpoint
input string   BroadcastAPIKey = "b80f66634faa378831fe572fe9e2ae326ef5daec11a0e56711d9281202e1eea1"; // Broadcast API Key
input bool     ExecuteOnMaster = true;                    // Also execute trades on THIS account

input group "=== Server Configuration ==="
input string   ServerURL = "https://fxbot-server-production.up.railway.app/api";
input int      MagicNumber = 236878;                     // Magic Number (Admin EA Account)
input bool     EnableServerConnection = true;            // Connect to server
input int      HeartbeatIntervalSec = 30;                // Heartbeat interval (seconds)

input group "=== Trading Settings ==="
input double   RiskPercent = 1.0;                        // Risk per trade (% of balance)
input int      WickClearancePips = 5;                    // SL clearance below/above wick (pips)
input int      SpreadBufferPips = 10;                    // Extra SL buffer for spread protection (pips)
input int      MaxStopLossPips = 100;                    // Maximum SL distance allowed (pips)
input bool     EnableSecondTrade = true;                 // Enable second layer entry
input int      Slippage = 30;                            // Maximum slippage (points)

input group "=== Engulfing Detection ==="
input double   TolerancePips = 5.0;                      // Tolerance for open/close matching (pips)
input double   MinBodySizePips = 1.0;                    // Minimum candle body size (pips)

input group "=== Protection ==="
input int      MaxSpreadPips = 30;                       // Maximum spread allowed (pips)
input int      MaxTradesPerDay = 0;                      // Max trades per day (0 = unlimited)
input int      MaxConsecutiveLosses = 3;                 // Consecutive losses before rest (0 = disabled)
input int      RestPeriodMinutes = 10;                   // Rest period after max consecutive losses (minutes)

input group "=== Backtest Export ==="
input bool     ExportBacktestCSV = true;                 // Export trades to CSV in Strategy Tester
input string   CSVFileName = "GoldEngulfingBot_Backtest.csv"; // CSV file name

input group "=== Debug ==="
input bool     EnableLogs = true;                        // Enable debug logging

//+------------------------------------------------------------------+
//| Global Variables                                                 |
//+------------------------------------------------------------------+
CTrade trade;
CPositionInfo position;
CAccountInfo account;

// Symbol metrics
double g_pipSize = 0.01;      // Gold pip = $0.01
double g_pipValue = 1.0;      // Pip value per standard lot
double g_point = 0;
int g_digits = 0;
double g_minLot = 0.01;
double g_maxLot = 100.0;
double g_lotStep = 0.01;

// Engulfing bar data
struct EngulfingBar {
    double open;
    double high;
    double low;
    double close;
    datetime time;
    bool isBullish;
    bool isValid;
};

// Bot state
EngulfingBar g_engulfing;
bool g_firstTradeOpen = false;
bool g_secondTradeOpen = false;
ulong g_firstTicket = 0;
ulong g_secondTicket = 0;
datetime g_firstTradeBarTime = 0;    // Bar time when Trade #1 was opened
int g_secondTradeBarCount = 0;
int g_dailyTrades = 0;
datetime g_dailyResetTime = 0;
bool g_botEnabled = true;

// Consecutive loss tracking
int g_consecutiveLosses = 0;
datetime g_restPeriodEnd = 0;
double g_lastTradeProfit = 0;

// Server connection
string g_sessionId = "";
string g_jwtToken = "";
datetime g_lastHeartbeat = 0;
datetime g_lastPositionUpdate = 0;
datetime g_lastHttpErrorLog = 0;

// Backtest CSV tracking
int g_csvHandle = INVALID_HANDLE;
int g_tradeCounter = 0;

//+------------------------------------------------------------------+
//| Logging function                                                 |
//+------------------------------------------------------------------+
void Log(string msg, string cat = "INFO") {
    if(EnableLogs) Print("[", cat, "] ", msg);
}

//+------------------------------------------------------------------+
//| Get descriptive WebRequest error message                         |
//+------------------------------------------------------------------+
string GetLastWebRequestError() {
    int error = GetLastError();
    switch(error) {
        case 4014: return "URL not in allowed list - add to Tools>Options>Expert Advisors";
        case 4024: return "WebRequest not allowed for EA";
        case 4060: return "Invalid URL format";
        case 5200: return "No internet connection";
        case 5201: return "Invalid URL specified";
        case 5202: return "Failed to connect to server";
        case 5203: return "WebRequest timeout";
        case 5204: return "HTTP request failed";
        default: return "Error code: " + IntegerToString(error);
    }
}

//+------------------------------------------------------------------+
//| Test server connectivity on startup                              |
//+------------------------------------------------------------------+
bool TestServerConnectivity() {
    if(!BroadcastMode || StringLen(BroadcastURL) == 0) {
        return true; // Skip test if broadcast mode is off
    }

    Log("Testing server connectivity...", "INIT");

    // Extract base URL and add ping endpoint
    string baseUrl = BroadcastURL;
    int apiPos = StringFind(baseUrl, "/api/signals");
    if(apiPos > 0) {
        baseUrl = StringSubstr(baseUrl, 0, apiPos);
    }
    string pingUrl = baseUrl + "/api/signals/ea/ping";

    Log("Ping URL: " + pingUrl, "DEBUG");

    char post[], result[];
    string responseHeaders = "";
    ResetLastError();

    int res = WebRequest("GET", pingUrl, "", 5000, post, result, responseHeaders);

    if(res == -1) {
        int error = GetLastError();
        string errorMsg = GetLastWebRequestError();
        Log("Server connectivity FAILED! " + errorMsg, "ERROR");

        if(error == 4014) {
            Alert("FXBot EA: Add URL to MT5 allowed list!\n" +
                  "Go to: Tools > Options > Expert Advisors\n" +
                  "Add: " + baseUrl);
        }
        return false;
    }

    if(res == 200) {
        string response = CharArrayToString(result);
        Log("Server connectivity OK: " + response, "INIT");
        return true;
    }

    Log("Server returned HTTP " + IntegerToString(res), "WARN");
    return false;
}

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit() {
    Log("========================================", "INIT");
    Log("Gold Engulfing Bot v5.1 Starting", "INIT");
    Log("v5.1: Trade #2 SL = wider of confirmation or 50% engulfing body", "INIT");

    if(BroadcastMode) {
        Log("*** SIGNAL BROADCAST MODE ENABLED ***", "INIT");
        Log("Signals will be sent to: " + BroadcastURL, "INIT");
        if(ExecuteOnMaster) {
            Log("Also executing on this (master) account", "INIT");
        } else {
            Log("NOT executing on this account (signal relay only)", "INIT");
        }
    }

    // Setup trade class
    trade.SetExpertMagicNumber(MagicNumber);
    trade.SetDeviationInPoints(Slippage);
    trade.SetTypeFilling(ORDER_FILLING_IOC);

    // Validate symbol is Gold
    string sym = _Symbol;
    StringToUpper(sym);
    if(StringFind(sym, "XAU") < 0 && StringFind(sym, "GOLD") < 0) {
        Alert("This EA only works on Gold (XAU/GOLD)!");
        return INIT_FAILED;
    }

    // Validate timeframe
    if(_Period != PERIOD_H1 && _Period != PERIOD_M15 && _Period != PERIOD_M1) {
        Alert("This EA works on H1, M15, and M1 timeframes only!");
        return INIT_FAILED;
    }

    // Get symbol specifications
    g_digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    g_point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    g_minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    g_maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    g_lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

    double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);

    // GOLD PIP CALCULATION
    if(g_digits == 3) {
        g_pipSize = g_point * 10;  // 0.001 * 10 = 0.01
    } else {
        g_pipSize = g_point;       // 0.01
    }

    // Pip value per lot
    g_pipValue = tickValue * (g_pipSize / tickSize);

    // Initialize daily tracking
    g_dailyResetTime = TimeCurrent();
    g_dailyTrades = 0;
    g_consecutiveLosses = 0;
    g_restPeriodEnd = 0;

    Log("Symbol: " + _Symbol + " | TF: " + EnumToString((ENUM_TIMEFRAMES)_Period), "INIT");
    Log("1 Pip = $" + DoubleToString(g_pipSize, g_digits), "INIT");
    Log("Pip Value = $" + DoubleToString(g_pipValue, 2) + "/lot", "INIT");
    Log("Balance: $" + DoubleToString(account.Balance(), 2), "INIT");
    Log("Risk: " + DoubleToString(RiskPercent, 2) + "% | Max SL: " + IntegerToString(MaxStopLossPips) + " pips", "INIT");

    // Initialize CSV for Strategy Tester
    if(MQLInfoInteger(MQL_TESTER) && ExportBacktestCSV) {
        InitBacktestCSV();
    }

    // Server authentication or broadcast connectivity test
    if(EnableServerConnection && !BroadcastMode) {
        AuthenticateWithServer();
    } else if(BroadcastMode) {
        Log("Broadcast mode - using direct signal endpoint", "INIT");
        Log("Broadcast URL: " + BroadcastURL, "INIT");

        // Test connectivity to server
        if(!TestServerConnectivity()) {
            Log("*** WARNING: Server connectivity test FAILED! ***", "WARN");
            Log("Signals will NOT be broadcast until URL is whitelisted!", "WARN");
            Log("Add to MT5: Tools > Options > Expert Advisors", "WARN");
        }
    } else {
        Log("Server connection: DISABLED", "INIT");
    }

    Log("========================================", "INIT");
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Convert price difference to pips                                 |
//+------------------------------------------------------------------+
double ToPips(double priceDiff) {
    return MathAbs(priceDiff) / g_pipSize;
}

//+------------------------------------------------------------------+
//| Convert pips to price difference                                 |
//+------------------------------------------------------------------+
double ToPrice(double pips) {
    return pips * g_pipSize;
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick() {
    if(!g_botEnabled) return;

    // Daily reset check
    CheckDailyReset();

    // Server heartbeat - every HeartbeatIntervalSec seconds
    if(EnableServerConnection && !BroadcastMode && TimeCurrent() - g_lastHeartbeat > HeartbeatIntervalSec) {
        SendHeartbeat();
        g_lastHeartbeat = TimeCurrent();
    }

    // Position updates - every 5 seconds (real-time)
    if(EnableServerConnection && !BroadcastMode && TimeCurrent() - g_lastPositionUpdate > 5) {
        SendPositionUpdate();
        g_lastPositionUpdate = TimeCurrent();
    }

    // Account update for broadcast mode - every HeartbeatIntervalSec seconds
    // This keeps admin EA account balance up-to-date on the server
    if(BroadcastMode && TimeCurrent() - g_lastHeartbeat > HeartbeatIntervalSec) {
        SendAccountUpdate();
        g_lastHeartbeat = TimeCurrent();
    }

    // Check for new bar
    static datetime lastBar = 0;
    datetime currentBar = iTime(_Symbol, PERIOD_CURRENT, 0);

    if(lastBar != currentBar) {
        lastBar = currentBar;
        OnNewBar();
    }
}

//+------------------------------------------------------------------+
//| Check and reset daily counters                                   |
//+------------------------------------------------------------------+
void CheckDailyReset() {
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);

    if(dt.hour == 0 && dt.min == 0) {
        MqlDateTime resetDt;
        TimeToStruct(g_dailyResetTime, resetDt);

        if(resetDt.day_of_year != dt.day_of_year) {
            g_dailyTrades = 0;
            g_consecutiveLosses = 0;
            g_restPeriodEnd = 0;
            g_dailyResetTime = TimeCurrent();
            Log("Daily counters reset", "RESET");
        }
    }
}

//+------------------------------------------------------------------+
//| New bar handler                                                  |
//+------------------------------------------------------------------+
void OnNewBar() {
    Log("========== NEW BAR ==========", "BAR");
    Log("Trade1=" + (g_firstTradeOpen ? "OPEN" : "closed") +
        " | Trade2=" + (g_secondTradeOpen ? "OPEN" : "closed") +
        " | Losses=" + IntegerToString(g_consecutiveLosses), "STATE");

    // Check if in rest period after consecutive losses
    if(g_restPeriodEnd > 0 && TimeCurrent() < g_restPeriodEnd) {
        int remainingSec = (int)(g_restPeriodEnd - TimeCurrent());
        Log("REST PERIOD: " + IntegerToString(remainingSec / 60) + "m " +
            IntegerToString(remainingSec % 60) + "s remaining", "REST");
        return;
    } else if(g_restPeriodEnd > 0 && TimeCurrent() >= g_restPeriodEnd) {
        Log("Rest period ended - resuming trading", "REST");
        g_restPeriodEnd = 0;
        g_consecutiveLosses = 0;
    }

    // Check spread
    double spreadPips = ToPips(SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID));
    Log("Spread: " + DoubleToString(spreadPips, 1) + " pips", "CHECK");

    if(spreadPips > MaxSpreadPips) {
        Log("BLOCKED: Spread too high", "CHECK");
        return;
    }

    // Check daily limit
    if(MaxTradesPerDay > 0 && g_dailyTrades >= MaxTradesPerDay) {
        Log("BLOCKED: Daily limit reached", "CHECK");
        return;
    }

    //----------------------------------------------------------
    // TRADE FLOW LOGIC
    //----------------------------------------------------------

    // CASE 1: Second trade is open - monitor for exit after 1 bar
    if(g_secondTradeOpen) {
        g_secondTradeBarCount++;
        Log("Trade #2 bar count: " + IntegerToString(g_secondTradeBarCount), "MONITOR");

        if(g_secondTradeBarCount >= 1) {
            Log("Closing Trade #2 after 1 complete bar", "EXIT");

            // Broadcast close signal
            if(BroadcastMode) {
                BroadcastCloseSignal();
            }

            if(ExecuteOnMaster || !BroadcastMode) {
                CloseTradeByTicket(g_secondTicket);
            }

            g_secondTradeOpen = false;
            g_secondTicket = 0;
            g_secondTradeBarCount = 0;
            ResetState();
        }
        return;
    }

    // CASE 2: First trade is open - check for second trade condition on NEXT bar
    if(g_firstTradeOpen) {
        datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);

        if(currentBarTime > g_firstTradeBarTime) {
            Log("Checking confirmation for Trade #2...", "SECOND");
            CheckSecondTradeCondition();
        } else {
            Log("Waiting for next bar to check confirmation", "WAIT");
        }
        return;
    }

    // CASE 3: No trades open - look for new engulfing pattern
    EngulfingBar bar;
    if(DetectEngulfing(bar)) {
        g_engulfing = bar;
        OpenFirstTrade();
    }
}

//+------------------------------------------------------------------+
//| ENGULFING DETECTION                                              |
//+------------------------------------------------------------------+
bool DetectEngulfing(EngulfingBar &bar) {
    // Previous candle (index 2)
    double prevOpen = iOpen(_Symbol, PERIOD_CURRENT, 2);
    double prevClose = iClose(_Symbol, PERIOD_CURRENT, 2);
    double prevHigh = iHigh(_Symbol, PERIOD_CURRENT, 2);
    double prevLow = iLow(_Symbol, PERIOD_CURRENT, 2);

    // Current closed candle (index 1)
    double currOpen = iOpen(_Symbol, PERIOD_CURRENT, 1);
    double currClose = iClose(_Symbol, PERIOD_CURRENT, 1);
    double currHigh = iHigh(_Symbol, PERIOD_CURRENT, 1);
    double currLow = iLow(_Symbol, PERIOD_CURRENT, 1);

    // Body sizes in PIPS
    double prevBodyPips = ToPips(prevOpen - prevClose);
    double currBodyPips = ToPips(currOpen - currClose);

    Log("--- Candle Analysis ---", "CANDLE");
    Log("PREV: O=" + DoubleToString(prevOpen, g_digits) +
        " C=" + DoubleToString(prevClose, g_digits) +
        " | Body: " + DoubleToString(prevBodyPips, 1) + " pips", "CANDLE");
    Log("CURR: O=" + DoubleToString(currOpen, g_digits) +
        " C=" + DoubleToString(currClose, g_digits) +
        " | Body: " + DoubleToString(currBodyPips, 1) + " pips", "CANDLE");

    // Minimum body size
    if(currBodyPips < MinBodySizePips || prevBodyPips < MinBodySizePips) {
        Log("Body too small", "PATTERN");
        return false;
    }

    // Directions
    bool prevBullish = (prevClose > prevOpen);
    bool currBullish = (currClose > currOpen);

    Log("Prev: " + (prevBullish ? "BULLISH" : "BEARISH") +
        " | Curr: " + (currBullish ? "BULLISH" : "BEARISH"), "CANDLE");

    // Tolerance
    double tol = ToPrice(TolerancePips);

    // ===== BULLISH ENGULFING =====
    if(currBullish && !prevBullish) {
        Log("Checking BULLISH engulfing...", "CHECK");

        bool closeEngulfs = (currClose >= prevOpen);
        bool openOK = (currOpen <= prevClose + tol);

        if(closeEngulfs && openOK) {
            double slPrice = currLow - ToPrice(WickClearancePips) - ToPrice(SpreadBufferPips);
            double slPips = ToPips(currClose - slPrice);

            Log(">>> BULLISH ENGULFING! <<<", "PATTERN");

            if(slPips > MaxStopLossPips) {
                Log("REJECTED: SL too far", "REJECT");
                return false;
            }

            bar.open = currOpen;
            bar.close = currClose;
            bar.high = currHigh;
            bar.low = currLow;
            bar.time = iTime(_Symbol, PERIOD_CURRENT, 1);
            bar.isBullish = true;
            bar.isValid = true;

            return true;
        }
    }

    // ===== BEARISH ENGULFING =====
    if(!currBullish && prevBullish) {
        Log("Checking BEARISH engulfing...", "CHECK");

        bool closeEngulfs = (currClose <= prevOpen);
        bool openOK = (currOpen >= prevClose - tol);

        if(closeEngulfs && openOK) {
            double slPrice = currHigh + ToPrice(WickClearancePips) + ToPrice(SpreadBufferPips);
            double slPips = ToPips(slPrice - currClose);

            Log(">>> BEARISH ENGULFING! <<<", "PATTERN");

            if(slPips > MaxStopLossPips) {
                Log("REJECTED: SL too far", "REJECT");
                return false;
            }

            bar.open = currOpen;
            bar.close = currClose;
            bar.high = currHigh;
            bar.low = currLow;
            bar.time = iTime(_Symbol, PERIOD_CURRENT, 1);
            bar.isBullish = false;
            bar.isValid = true;

            return true;
        }
    }

    Log("No engulfing pattern", "PATTERN");
    return false;
}

//+------------------------------------------------------------------+
//| Calculate lot size based on risk                                 |
//+------------------------------------------------------------------+
double CalcLots(double slPips) {
    Log("=== LOT CALCULATION ===", "LOTS");

    double balance = account.Balance();
    double riskMoney = balance * (RiskPercent / 100.0);

    Log("Balance: $" + DoubleToString(balance, 2), "LOTS");
    Log("Risk: $" + DoubleToString(riskMoney, 2) + " (" + DoubleToString(RiskPercent, 2) + "%)", "LOTS");
    Log("SL: " + DoubleToString(slPips, 1) + " pips | PipVal: $" + DoubleToString(g_pipValue, 2), "LOTS");

    if(slPips <= 0 || g_pipValue <= 0) {
        Log("ERROR: Invalid SL or pip value", "LOTS");
        return g_minLot;
    }

    // Lot size = Risk $ / (SL pips * pip value per lot)
    double lots = riskMoney / (slPips * g_pipValue);
    Log("Raw: " + DoubleToString(lots, 4), "LOTS");

    // Round DOWN to lot step
    lots = MathFloor(lots / g_lotStep) * g_lotStep;

    // Apply min/max
    lots = MathMax(lots, g_minLot);
    lots = MathMin(lots, g_maxLot);

    // Verify margin
    double marginReq = 0;
    if(OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, lots, SymbolInfoDouble(_Symbol, SYMBOL_ASK), marginReq)) {
        if(marginReq > account.FreeMargin() * 0.8) {
            Log("Reducing due to margin", "LOTS");
            lots = g_minLot;
        }
    }

    // Final risk
    double actualRisk = lots * slPips * g_pipValue;
    Log("=== FINAL: " + DoubleToString(lots, 2) + " lots ($" +
        DoubleToString(actualRisk, 2) + " risk) ===", "LOTS");

    return NormalizeDouble(lots, 2);
}

//+------------------------------------------------------------------+
//| Open first trade                                                 |
//+------------------------------------------------------------------+
void OpenFirstTrade() {
    Log("==========================================", "TRADE");
    Log(">>> OPENING TRADE #1 <<<", "TRADE");

    if(!g_engulfing.isValid) {
        Log("ABORT: Invalid engulfing", "TRADE");
        return;
    }

    double entry, sl, slPips;
    string action;

    if(g_engulfing.isBullish) {
        entry = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        sl = g_engulfing.low - ToPrice(WickClearancePips) - ToPrice(SpreadBufferPips);
        slPips = ToPips(entry - sl);
        action = "BUY";
        Log("BUY | Entry: " + DoubleToString(entry, g_digits) +
            " | SL: " + DoubleToString(sl, g_digits) +
            " (" + DoubleToString(slPips, 1) + " pips)", "TRADE");
    } else {
        entry = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        sl = g_engulfing.high + ToPrice(WickClearancePips) + ToPrice(SpreadBufferPips);
        slPips = ToPips(sl - entry);
        action = "SELL";
        Log("SELL | Entry: " + DoubleToString(entry, g_digits) +
            " | SL: " + DoubleToString(sl, g_digits) +
            " (" + DoubleToString(slPips, 1) + " pips)", "TRADE");
    }

    double lots = CalcLots(slPips);
    if(lots < g_minLot) {
        Log("ABORT: Lot size too small", "TRADE");
        return;
    }

    // BROADCAST MODE: Send signal to server for multi-account execution
    if(BroadcastMode) {
        string pattern = g_engulfing.isBullish ? "BULLISH_ENGULFING" : "BEARISH_ENGULFING";
        BroadcastTradeSignal(action, sl, RiskPercent, pattern);
    }

    // Execute on master account (or if broadcast mode is off)
    if(ExecuteOnMaster || !BroadcastMode) {
        string comment = g_engulfing.isBullish ? "GoldEngulf_Buy1" : "GoldEngulf_Sell1";
        bool success;

        if(g_engulfing.isBullish) {
            success = trade.Buy(lots, _Symbol, 0, sl, 0, comment);
        } else {
            success = trade.Sell(lots, _Symbol, 0, sl, 0, comment);
        }

        if(success) {
            g_firstTradeOpen = true;
            g_firstTicket = trade.ResultOrder();
            g_firstTradeBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
            g_dailyTrades++;

            Log(">>> TRADE #1 OPENED! <<<", "SUCCESS");
            Log("Ticket: " + IntegerToString(g_firstTicket) +
                " | Price: " + DoubleToString(trade.ResultPrice(), g_digits) +
                " | Lots: " + DoubleToString(lots, 2), "SUCCESS");

            // Record for backtest CSV
            if(MQLInfoInteger(MQL_TESTER) && ExportBacktestCSV) {
                RecordTradeOpen(g_firstTicket, action, lots, trade.ResultPrice(), sl, 1);
            }

            if(EnableServerConnection && !BroadcastMode) {
                SendTradeNotification(action, lots, trade.ResultPrice(), sl);
            }
        } else {
            Log("FAILED! " + trade.ResultRetcodeDescription(), "ERROR");
        }
    } else {
        // In broadcast-only mode, still track state
        g_firstTradeOpen = true;
        g_firstTradeBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
        g_dailyTrades++;
        Log("Signal broadcast - not executing on master", "BROADCAST");
    }

    Log("==========================================", "TRADE");
}

//+------------------------------------------------------------------+
//| Check condition for second trade (called on NEXT bar)            |
//+------------------------------------------------------------------+
void CheckSecondTradeCondition() {
    // Get confirmation candle (index 1 = the bar that just closed)
    double lastOpen = iOpen(_Symbol, PERIOD_CURRENT, 1);
    double lastClose = iClose(_Symbol, PERIOD_CURRENT, 1);
    double lastHigh = iHigh(_Symbol, PERIOD_CURRENT, 1);
    double lastLow = iLow(_Symbol, PERIOD_CURRENT, 1);

    bool lastBullish = (lastClose > lastOpen);
    bool sameDirection = g_engulfing.isBullish ? lastBullish : !lastBullish;

    Log("Confirmation candle: " + (lastBullish ? "BULLISH" : "BEARISH"), "SECOND");
    Log("Same direction as engulfing: " + (sameDirection ? "YES" : "NO"), "SECOND");

    // Broadcast close signal for Trade #1
    if(BroadcastMode) {
        BroadcastCloseSignal();
    }

    // Close first trade on master
    if(ExecuteOnMaster || !BroadcastMode) {
        Log("Closing Trade #1...", "CLOSE");
        CloseTradeByTicket(g_firstTicket);
    }

    g_firstTradeOpen = false;
    g_firstTicket = 0;

    // Check if second trade should be opened
    if(sameDirection && EnableSecondTrade) {
        Log("Opening Trade #2...", "SECOND");
        OpenSecondTrade(lastLow, lastHigh);
    } else {
        Log("No Trade #2 - confirmation failed", "SECOND");
        ResetState();
    }
}

//+------------------------------------------------------------------+
//| Open second trade                                                |
//| v5.1: SL is WIDER of Trade1 candle wick SL or 50% engulfing body |
//+------------------------------------------------------------------+
void OpenSecondTrade(double lastLow, double lastHigh) {
    Log("==========================================", "TRADE");
    Log(">>> OPENING TRADE #2 <<<", "TRADE");

    double entry, sl, slPips;
    string action;

    // v5.1: Calculate 50% body level of the engulfing candle
    double midBody = (g_engulfing.open + g_engulfing.close) / 2.0;

    if(g_engulfing.isBullish) {
        entry = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

        // Trade 1 candle (confirmation) wick SL - original v5.0 logic
        double confirmationSL = lastLow - ToPrice(WickClearancePips) - ToPrice(SpreadBufferPips);

        // v5.1: 50% body SL (middle of engulfing candle body)
        double bodySL = midBody - ToPrice(SpreadBufferPips);

        // Use the WIDER SL (lower price for BUY = further from entry = more protection)
        sl = MathMin(confirmationSL, bodySL);

        Log("Trade #2 SL Calc: Trade1Wick=" + DoubleToString(confirmationSL, g_digits) +
            " | 50%Body=" + DoubleToString(bodySL, g_digits) +
            " | Using=" + DoubleToString(sl, g_digits) +
            (sl == bodySL ? " (50% BODY)" : " (TRADE1 WICK)"), "SL");

        slPips = ToPips(entry - sl);
        action = "BUY";
    } else {
        entry = SymbolInfoDouble(_Symbol, SYMBOL_BID);

        // Trade 1 candle (confirmation) wick SL - original v5.0 logic
        double confirmationSL = lastHigh + ToPrice(WickClearancePips) + ToPrice(SpreadBufferPips);

        // v5.1: 50% body SL (middle of engulfing candle body)
        double bodySL = midBody + ToPrice(SpreadBufferPips);

        // Use the WIDER SL (higher price for SELL = further from entry = more protection)
        sl = MathMax(confirmationSL, bodySL);

        Log("Trade #2 SL Calc: Trade1Wick=" + DoubleToString(confirmationSL, g_digits) +
            " | 50%Body=" + DoubleToString(bodySL, g_digits) +
            " | Using=" + DoubleToString(sl, g_digits) +
            (sl == bodySL ? " (50% BODY)" : " (TRADE1 WICK)"), "SL");

        slPips = ToPips(sl - entry);
        action = "SELL";
    }

    double lots = CalcLots(slPips);
    if(lots < g_minLot) {
        Log("ABORT: Lot size too small", "TRADE");
        ResetState();
        return;
    }

    // BROADCAST MODE: Send signal to server
    if(BroadcastMode) {
        string pattern = g_engulfing.isBullish ? "BULLISH_ENGULFING_T2" : "BEARISH_ENGULFING_T2";
        BroadcastTradeSignal(action, sl, RiskPercent, pattern);
    }

    // Execute on master account
    if(ExecuteOnMaster || !BroadcastMode) {
        string comment = g_engulfing.isBullish ? "GoldEngulf_Buy2" : "GoldEngulf_Sell2";
        bool success;

        if(g_engulfing.isBullish) {
            success = trade.Buy(lots, _Symbol, 0, sl, 0, comment);
        } else {
            success = trade.Sell(lots, _Symbol, 0, sl, 0, comment);
        }

        if(success) {
            g_secondTradeOpen = true;
            g_secondTicket = trade.ResultOrder();
            g_secondTradeBarCount = 0;
            g_dailyTrades++;

            Log(">>> TRADE #2 OPENED! <<<", "SUCCESS");
            Log("Ticket: " + IntegerToString(g_secondTicket), "SUCCESS");

            // Record for backtest CSV
            if(MQLInfoInteger(MQL_TESTER) && ExportBacktestCSV) {
                RecordTradeOpen(g_secondTicket, action, lots, trade.ResultPrice(), sl, 2);
            }

            if(EnableServerConnection && !BroadcastMode) {
                SendTradeNotification(action, lots, trade.ResultPrice(), sl);
            }
        } else {
            Log("FAILED! " + trade.ResultRetcodeDescription(), "ERROR");
            ResetState();
        }
    } else {
        g_secondTradeOpen = true;
        g_secondTradeBarCount = 0;
        g_dailyTrades++;
    }

    Log("==========================================", "TRADE");
}

//+------------------------------------------------------------------+
//| Close trade by ticket and track result                           |
//+------------------------------------------------------------------+
void CloseTradeByTicket(ulong ticket) {
    if(ticket == 0) return;

    if(position.SelectByTicket(ticket)) {
        double profit = position.Profit() + position.Swap() + position.Commission();
        double closePrice = position.PriceCurrent();

        Log("Closing ticket: " + IntegerToString(ticket) +
            " | P/L: $" + DoubleToString(profit, 2), "CLOSE");

        if(trade.PositionClose(ticket)) {
            // Record for backtest CSV
            if(MQLInfoInteger(MQL_TESTER) && ExportBacktestCSV) {
                RecordTradeClose(ticket, closePrice, profit);
            }

            // Track consecutive losses
            g_lastTradeProfit = profit;

            if(profit < 0) {
                g_consecutiveLosses++;
                Log("Consecutive losses: " + IntegerToString(g_consecutiveLosses), "LOSS");

                if(MaxConsecutiveLosses > 0 && g_consecutiveLosses >= MaxConsecutiveLosses) {
                    g_restPeriodEnd = TimeCurrent() + (RestPeriodMinutes * 60);
                    Log(">>> REST PERIOD STARTED <<<", "REST");
                }
            } else {
                if(g_consecutiveLosses > 0) {
                    Log("Win - consecutive losses reset", "WIN");
                }
                g_consecutiveLosses = 0;
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Reset state                                                      |
//+------------------------------------------------------------------+
void ResetState() {
    Log("State reset", "STATE");
    g_engulfing.isValid = false;
    g_firstTradeOpen = false;
    g_secondTradeOpen = false;
    g_firstTicket = 0;
    g_secondTicket = 0;
    g_firstTradeBarTime = 0;
    g_secondTradeBarCount = 0;
}

//+------------------------------------------------------------------+
//| BROADCAST FUNCTIONS - Send signals to server                     |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Broadcast trade signal to server                                 |
//+------------------------------------------------------------------+
bool BroadcastTradeSignal(string action, double sl, double risk, string pattern) {
    if(StringLen(BroadcastURL) == 0 || StringLen(BroadcastAPIKey) == 0) {
        Log("Broadcast not configured", "BROADCAST");
        return false;
    }

    Log("Broadcasting " + action + " signal...", "BROADCAST");

    // Build URL with query parameters (MQL5 WebRequest compatible)
    string url = BroadcastURL + "?api_key=" + BroadcastAPIKey;
    url += "&action=" + action;
    url += "&symbol=" + _Symbol;
    url += "&sl=" + DoubleToString(sl, g_digits);
    url += "&risk=" + DoubleToString(risk, 2);
    url += "&pattern=" + pattern;
    // Include entry price (ASK for BUY, BID for SELL)
    double entryPrice = (action == "BUY") ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
    url += "&entry=" + DoubleToString(entryPrice, g_digits);
    // Include account balance data for admin EA tracking
    url += "&balance=" + DoubleToString(account.Balance(), 2);
    url += "&equity=" + DoubleToString(account.Equity(), 2);
    url += "&margin=" + DoubleToString(account.Margin(), 2);
    url += "&freeMargin=" + DoubleToString(account.FreeMargin(), 2);

    Log("Broadcast URL: " + url, "DEBUG");

    char post[], result[];
    string responseHeaders = "";
    ResetLastError();

    int res = WebRequest("POST", url, "", 10000, post, result, responseHeaders);

    if(res == -1) {
        int error = GetLastError();
        string errorMsg = GetLastWebRequestError();
        Log("Broadcast FAILED: HTTP -1 | " + errorMsg, "ERROR");

        if(error == 4014) {
            // Extract base URL for the alert
            string baseUrl = BroadcastURL;
            int apiPos = StringFind(baseUrl, "/api/");
            if(apiPos > 0) baseUrl = StringSubstr(baseUrl, 0, apiPos);

            Alert("FXBot EA: Add URL to MT5!\n" +
                  "Tools > Options > Expert Advisors\n" +
                  "Add: " + baseUrl);
        }
        return false;
    }

    if(res == 200) {
        string response = CharArrayToString(result);
        Log("Broadcast SUCCESS: " + response, "BROADCAST");
        return true;
    } else {
        string response = CharArrayToString(result);
        Log("Broadcast failed: HTTP " + IntegerToString(res) + " | " + response, "BROADCAST");
        return false;
    }
}

//+------------------------------------------------------------------+
//| Broadcast close signal to server                                 |
//+------------------------------------------------------------------+
bool BroadcastCloseSignal() {
    if(StringLen(BroadcastURL) == 0 || StringLen(BroadcastAPIKey) == 0) {
        Log("Broadcast not configured", "BROADCAST");
        return false;
    }

    Log("Broadcasting CLOSE signal...", "BROADCAST");

    string url = BroadcastURL + "?api_key=" + BroadcastAPIKey;
    url += "&action=CLOSE";
    url += "&symbol=" + _Symbol;
    // Include account balance data for admin EA tracking
    url += "&balance=" + DoubleToString(account.Balance(), 2);
    url += "&equity=" + DoubleToString(account.Equity(), 2);
    url += "&margin=" + DoubleToString(account.Margin(), 2);
    url += "&freeMargin=" + DoubleToString(account.FreeMargin(), 2);

    Log("Close URL: " + url, "DEBUG");

    char post[], result[];
    string responseHeaders = "";
    ResetLastError();

    int res = WebRequest("POST", url, "", 10000, post, result, responseHeaders);

    if(res == -1) {
        int error = GetLastError();
        string errorMsg = GetLastWebRequestError();
        Log("Close broadcast FAILED: HTTP -1 | " + errorMsg, "ERROR");
        return false;
    }

    if(res == 200) {
        string response = CharArrayToString(result);
        Log("Close broadcast SUCCESS: " + response, "BROADCAST");
        return true;
    }

    Log("Close broadcast failed: HTTP " + IntegerToString(res), "BROADCAST");
    return false;
}

//+------------------------------------------------------------------+
//| Send periodic account update to server (for broadcast mode)      |
//+------------------------------------------------------------------+
bool SendAccountUpdate() {
    if(StringLen(BroadcastURL) == 0 || StringLen(BroadcastAPIKey) == 0) {
        return false;
    }

    // Extract base URL and build account endpoint
    string baseUrl = BroadcastURL;
    int apiPos = StringFind(baseUrl, "/api/signals/ea");
    if(apiPos > 0) {
        baseUrl = StringSubstr(baseUrl, 0, apiPos);
    }

    string url = baseUrl + "/api/signals/ea/account?api_key=" + BroadcastAPIKey;
    url += "&balance=" + DoubleToString(account.Balance(), 2);
    url += "&equity=" + DoubleToString(account.Equity(), 2);
    url += "&margin=" + DoubleToString(account.Margin(), 2);
    url += "&freeMargin=" + DoubleToString(account.FreeMargin(), 2);

    char post[], result[];
    string responseHeaders = "";
    ResetLastError();

    int res = WebRequest("POST", url, "", 5000, post, result, responseHeaders);

    if(res == 200) {
        Log("Account update sent: Bal=" + DoubleToString(account.Balance(), 2) +
            " Eq=" + DoubleToString(account.Equity(), 2), "ACCOUNT");
        return true;
    }

    return false;
}

//+------------------------------------------------------------------+
//| BACKTEST CSV EXPORT FUNCTIONS                                    |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Initialize CSV file for backtest export                          |
//+------------------------------------------------------------------+
void InitBacktestCSV() {
    g_csvHandle = FileOpen(CSVFileName, FILE_WRITE|FILE_CSV|FILE_ANSI, ',');

    if(g_csvHandle != INVALID_HANDLE) {
        // Write header
        FileWrite(g_csvHandle,
            "TradeNo", "Ticket", "Type", "TradeNum", "Symbol", "Lots",
            "OpenTime", "OpenPrice", "StopLoss",
            "CloseTime", "ClosePrice", "Profit", "Result"
        );
        Log("CSV file initialized: " + CSVFileName, "CSV");
    } else {
        Log("Failed to create CSV file", "CSV");
    }
}

//+------------------------------------------------------------------+
//| Record trade open to CSV                                         |
//+------------------------------------------------------------------+
void RecordTradeOpen(ulong ticket, string type, double lots, double price, double sl, int tradeNum) {
    if(g_csvHandle == INVALID_HANDLE) return;

    g_tradeCounter++;

    FileWrite(g_csvHandle,
        g_tradeCounter,
        ticket,
        type,
        tradeNum,
        _Symbol,
        DoubleToString(lots, 2),
        TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES),
        DoubleToString(price, g_digits),
        DoubleToString(sl, g_digits),
        "", "", "", "" // Close fields filled later
    );
}

//+------------------------------------------------------------------+
//| Record trade close to CSV (update last row)                      |
//+------------------------------------------------------------------+
void RecordTradeClose(ulong ticket, double closePrice, double profit) {
    // For simplicity in Strategy Tester, we write a new completion row
    if(g_csvHandle == INVALID_HANDLE) return;

    string result = "BREAKEVEN";
    if(profit > 0.01) result = "WIN";
    else if(profit < -0.01) result = "LOSS";

    FileWrite(g_csvHandle,
        "", // TradeNo
        ticket,
        "CLOSE",
        "",
        _Symbol,
        "",
        "", "", "",
        TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES),
        DoubleToString(closePrice, g_digits),
        DoubleToString(profit, 2),
        result
    );
}

//+------------------------------------------------------------------+
//| SERVER COMMUNICATION FUNCTIONS (Original)                        |
//+------------------------------------------------------------------+

bool SendHTTPRequest(string endpoint, string method, string &data, string &response) {
    string headers = "Content-Type: application/json\r\n";

    if(StringLen(g_jwtToken) > 0) {
        headers += "Authorization: Bearer " + g_jwtToken + "\r\n";
    }
    if(StringLen(g_sessionId) > 0) {
        headers += "X-Session-Id: " + g_sessionId + "\r\n";
    }

    char post[], result[];
    int dataLen = StringLen(data);
    ArrayResize(post, dataLen);
    StringToCharArray(data, post, 0, dataLen);

    string url = ServerURL + endpoint;
    string responseHeaders = "";

    int res = WebRequest(method, url, headers, 5000, post, result, responseHeaders);

    if(res == 200 || res == 201) {
        response = CharArrayToString(result);
        return true;
    }

    if(TimeCurrent() - g_lastHttpErrorLog >= 60) {
        Log("Server error: " + endpoint + " code=" + IntegerToString(res), "HTTP");
        g_lastHttpErrorLog = TimeCurrent();
    }

    return false;
}

string ExtractJsonString(string &json, string key) {
    string searchKey = "\"" + key + "\":\"";
    int start = StringFind(json, searchKey);
    if(start < 0) return "";

    start += StringLen(searchKey);
    int end = StringFind(json, "\"", start);
    if(end < 0) return "";

    return StringSubstr(json, start, end - start);
}

bool AuthenticateWithServer() {
    Log("Authenticating with server...", "AUTH");

    string data = "{";
    data += "\"magicNumber\":" + IntegerToString(MagicNumber) + ",";
    data += "\"accountNumber\":\"" + IntegerToString(account.Login()) + "\",";
    data += "\"broker\":\"" + account.Company() + "\",";
    data += "\"symbol\":\"" + _Symbol + "\",";
    data += "\"version\":\"5.1.0\"";
    data += "}";

    string response;
    if(SendHTTPRequest("/mt5/auth", "POST", data, response)) {
        g_sessionId = ExtractJsonString(response, "sessionId");
        g_jwtToken = ExtractJsonString(response, "jwtToken");

        if(StringLen(g_sessionId) > 0 && StringLen(g_jwtToken) > 0) {
            Log("Authentication successful!", "AUTH");
            return true;
        }
    }

    Log("Authentication failed - will retry", "AUTH");
    return false;
}

void SendHeartbeat() {
    string data = "{";
    data += "\"balance\":" + DoubleToString(account.Balance(), 2) + ",";
    data += "\"equity\":" + DoubleToString(account.Equity(), 2) + ",";
    data += "\"margin\":" + DoubleToString(account.Margin(), 2) + ",";
    data += "\"freeMargin\":" + DoubleToString(account.FreeMargin(), 2) + ",";
    data += "\"openPositions\":" + IntegerToString(PositionsTotal()) + ",";
    data += "\"botEnabled\":" + (g_botEnabled ? "true" : "false") + ",";
    data += "\"dailyTrades\":" + IntegerToString(g_dailyTrades);
    data += "}";

    string response;
    if(SendHTTPRequest("/mt5/heartbeat", "POST", data, response)) {
        if(StringFind(response, "\"command\":\"stop\"") >= 0) {
            g_botEnabled = false;
            Log("Bot STOPPED by server", "CMD");
        } else if(StringFind(response, "\"command\":\"start\"") >= 0) {
            g_botEnabled = true;
            Log("Bot STARTED by server", "CMD");
        }
    }
}

void SendPositionUpdate() {
    string positions = "[";
    bool first = true;

    for(int i = 0; i < PositionsTotal(); i++) {
        if(position.SelectByIndex(i)) {
            if(position.Symbol() == _Symbol && position.Magic() == MagicNumber) {
                if(!first) positions += ",";

                positions += "{";
                positions += "\"ticket\":\"" + IntegerToString(position.Ticket()) + "\",";
                positions += "\"symbol\":\"" + position.Symbol() + "\",";
                positions += "\"type\":\"" + (position.PositionType() == POSITION_TYPE_BUY ? "BUY" : "SELL") + "\",";
                positions += "\"volume\":" + DoubleToString(position.Volume(), 2) + ",";
                positions += "\"openPrice\":" + DoubleToString(position.PriceOpen(), g_digits) + ",";
                positions += "\"currentPrice\":" + DoubleToString(position.PriceCurrent(), g_digits) + ",";
                positions += "\"stopLoss\":" + DoubleToString(position.StopLoss(), g_digits) + ",";
                positions += "\"profit\":" + DoubleToString(position.Profit(), 2);
                positions += "}";

                first = false;
            }
        }
    }

    positions += "]";

    string data = "{\"positions\":" + positions + "}";
    string response;
    SendHTTPRequest("/mt5/positions", "POST", data, response);
}

void SendTradeNotification(string type, double lots, double price, double sl) {
    string data = "{";
    data += "\"type\":\"" + type + "\",";
    data += "\"symbol\":\"" + _Symbol + "\",";
    data += "\"lots\":" + DoubleToString(lots, 2) + ",";
    data += "\"price\":" + DoubleToString(price, g_digits) + ",";
    data += "\"stopLoss\":" + DoubleToString(sl, g_digits) + ",";
    data += "\"magicNumber\":" + IntegerToString(MagicNumber);
    data += "}";

    string response;
    SendHTTPRequest("/mt5/trades", "POST", data, response);
}

void SendDisconnectionNotice(int reason) {
    string reasonStr;
    switch(reason) {
        case REASON_PROGRAM: reasonStr = "Expert removed"; break;
        case REASON_REMOVE: reasonStr = "Program removed"; break;
        case REASON_RECOMPILE: reasonStr = "Recompiled"; break;
        case REASON_CHARTCHANGE: reasonStr = "Chart changed"; break;
        case REASON_CHARTCLOSE: reasonStr = "Chart closed"; break;
        case REASON_PARAMETERS: reasonStr = "Parameters changed"; break;
        case REASON_ACCOUNT: reasonStr = "Account changed"; break;
        case REASON_TEMPLATE: reasonStr = "Template applied"; break;
        case REASON_CLOSE: reasonStr = "Terminal closed"; break;
        default: reasonStr = "Unknown"; break;
    }

    string data = "{";
    data += "\"reason\":" + IntegerToString(reason) + ",";
    data += "\"message\":\"" + reasonStr + "\"";
    data += "}";

    string response;
    SendHTTPRequest("/mt5/disconnect", "POST", data, response);
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
    // Close CSV file
    if(g_csvHandle != INVALID_HANDLE) {
        FileClose(g_csvHandle);
        Log("CSV file closed: " + CSVFileName, "CSV");
    }

    if(EnableServerConnection && !BroadcastMode) {
        SendDisconnectionNotice(reason);
    }

    Log("Bot stopped. Daily trades: " + IntegerToString(g_dailyTrades), "DEINIT");
}
//+------------------------------------------------------------------+
