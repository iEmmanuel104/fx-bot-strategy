//+------------------------------------------------------------------+
//|                                       EngulfingTrendATR_v1.mq5   |
//|                   Engulfing + Trend + TRIPLE SL METHOD           |
//|                                                       Version 1.2 |
//|  SINGLE TRADE SYSTEM with TRIPLE SL + Session Filter             |
//+------------------------------------------------------------------+
#property copyright "FXBot Trading"
#property link      "https://fxbot.trading"
#property version   "1.20"
#property strict
#property description "Engulfing Pattern + Dual EMA Trend Filter + TRIPLE SL METHOD"
#property description "SL = LARGEST of: ATR x 1.5, Wick + Clearance, 50% Body"
#property description "Features: 1:2 RR, Breakeven at 1:1, Session Filter"
#property description "Symbols: XAUUSD and GBPUSD only"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\AccountInfo.mqh>

//+------------------------------------------------------------------+
//| Input Parameters                                                 |
//+------------------------------------------------------------------+
input group "=== ATR Stop Loss Settings ==="
input int      ATR_Period       = 14;                    // ATR Period for SL calculation
input double   ATR_Multiplier   = 1.5;                   // ATR Multiplier (SL = ATR x Multiplier)

input group "=== Wick-Based SL Settings ==="
input int      WickClearancePips = 5;                    // SL clearance below/above wick (pips)
input int      SpreadBufferPips  = 10;                   // Extra SL buffer for spread protection (pips)

input group "=== Risk-Reward Settings ==="
input double   RiskRewardRatio  = 2.0;                   // Risk:Reward Ratio (1:X)
input bool     EnableBreakeven  = true;                  // Move SL to entry at 1:1
input double   BreakevenBuffer  = 0.5;                   // Buffer above/below entry (pips)

input group "=== Trend Filter (Dual EMA) ==="
input int      EMA_Fast_Period  = 20;                    // Fast EMA Period
input int      EMA_Slow_Period  = 50;                    // Slow EMA Period
input ENUM_APPLIED_PRICE EMA_Price = PRICE_CLOSE;        // Price for EMA calculation

input group "=== Risk Management ==="
input double   RiskPercent      = 1.0;                   // Risk per trade (% of balance)
input int      MagicNumber      = 987654;                // Magic Number (unique for this EA)
input int      Slippage         = 30;                    // Maximum slippage (points)

input group "=== Risk Per Trade ==="
input bool     UseFixedRisk     = false;                 // Use fixed $ risk instead of %
input double   FixedRiskAmount  = 50.0;                  // Fixed risk amount in $ per trade

input group "=== Daily P&L Limits ==="
input bool     EnableDailyLimits    = true;              // Enable daily P&L limits
input double   MaxDailyLossAmount   = 100.0;             // Max daily loss in $ (0 = disabled)
input double   MaxDailyLossPercent  = 5.0;               // Max daily loss in % of balance (0 = disabled)
input double   DailyProfitTarget    = 200.0;             // Daily profit target in $ (0 = disabled)
input double   DailyProfitPercent   = 10.0;              // Daily profit target in % (0 = disabled)
input bool     StopOnProfitTarget   = false;             // Stop trading when profit target reached

input group "=== Engulfing Detection ==="
input double   TolerancePips    = 2.0;                   // Tolerance for engulfing matching (pips)
input double   MinBodySizePips  = 3.0;                   // Minimum candle body size (pips)

input group "=== Protection ==="
input double   MaxSpreadPips    = 5.0;                   // Maximum spread allowed (pips)
input double   MaxATRPips       = 50.0;                  // Maximum ATR SL allowed (pips)
input int      MaxTradesPerDay  = 5;                     // Max trades per day (0 = unlimited)

input group "=== Debug ==="
input bool     EnableLogs       = true;                  // Enable debug logging

input group "=== Trading Sessions ==="
input bool     EnableSessionFilter = true;               // Enable session-based trading filter
input int      BrokerGMTOffset = 2;                      // Broker server GMT offset (e.g., 2 for GMT+2)

input group "=== Asian Session (Tokyo) ==="
input bool     TradeAsianSession = true;                 // Enable trading during Asian session
input int      AsianStartHour = 0;                       // Asian session start (GMT hour)
input int      AsianEndHour = 9;                         // Asian session end (GMT hour)

input group "=== London Session ==="
input bool     TradeLondonSession = true;                // Enable trading during London session
input int      LondonStartHour = 7;                      // London session start (GMT hour)
input int      LondonEndHour = 16;                       // London session end (GMT hour)

input group "=== New York Session ==="
input bool     TradeNewYorkSession = true;               // Enable trading during New York session
input int      NewYorkStartHour = 13;                    // New York session start (GMT hour)
input int      NewYorkEndHour = 22;                      // New York session end (GMT hour)

//+------------------------------------------------------------------+
//| Global Variables                                                 |
//+------------------------------------------------------------------+
CTrade trade;
CPositionInfo position;
CAccountInfo account;

// Symbol metrics - dynamically calculated
double g_pipSize = 0.0;
double g_pipValue = 0.0;
double g_point = 0.0;
int    g_digits = 0;
double g_minLot = 0.01;
double g_maxLot = 100.0;
double g_lotStep = 0.01;

// Indicator handles
int    g_atrHandle = INVALID_HANDLE;      // ATR indicator handle
int    g_emaFastHandle = INVALID_HANDLE;  // Fast EMA handle
int    g_emaSlowHandle = INVALID_HANDLE;  // Slow EMA handle

// Engulfing bar data (for Triple SL calculations)
struct EngulfingBar {
    double open;
    double high;
    double low;
    double close;
    datetime time;
    bool   isBullish;
    bool   isValid;
};
EngulfingBar g_engulfing;  // Stores last detected engulfing candle data

// State tracking
datetime g_lastBarTime = 0;               // For new bar detection
int      g_dailyTrades = 0;               // Daily trade counter
datetime g_dailyResetTime = 0;            // For daily reset
bool     g_botEnabled = true;             // Bot on/off state

// Daily P&L tracking
double   g_dailyStartBalance = 0;         // Balance at start of trading day
double   g_dailyPnL = 0;                  // Current day's realized P&L
double   g_dailyMaxLoss = 0;              // Calculated max loss for the day
double   g_dailyProfitGoal = 0;           // Calculated profit target for the day
bool     g_dailyLossLimitHit = false;     // Flag: daily loss limit reached
bool     g_dailyProfitTargetHit = false;  // Flag: daily profit target reached

// Session tracking
enum SESSION_TYPE {
    SESSION_NONE = 0,
    SESSION_ASIAN = 1,
    SESSION_LONDON = 2,
    SESSION_NEWYORK = 3,
    SESSION_OVERLAP_TOKYO_LONDON = 4,
    SESSION_OVERLAP_LONDON_NY = 5
};
SESSION_TYPE g_currentSession = SESSION_NONE;

// Auto-calculated symbol-specific parameters (set in OnInit)
double   g_activeMaxSpread = 5.0;         // Active max spread (pips)
double   g_activeMinBody = 3.0;           // Active min body size (pips)
double   g_activeMaxATR = 50.0;           // Active max ATR SL (pips)
double   g_activeTolerance = 2.0;         // Active engulfing tolerance (pips)
double   g_activeBreakevenBuffer = 0.5;   // Active breakeven buffer (pips)

//+------------------------------------------------------------------+
//| Logging function                                                 |
//+------------------------------------------------------------------+
void Log(string msg, string cat = "INFO") {
    if(EnableLogs) Print("[", cat, "] ", msg);
}

//+------------------------------------------------------------------+
//| Check if symbol is allowed (XAUUSD or GBPUSD only)               |
//+------------------------------------------------------------------+
bool IsSymbolAllowed() {
    string sym = _Symbol;
    StringToUpper(sym);

    if(StringFind(sym, "XAUUSD") >= 0 || StringFind(sym, "XAU") >= 0 || StringFind(sym, "GOLD") >= 0)
        return true;
    if(StringFind(sym, "GBPUSD") >= 0)
        return true;

    return false;
}

//+------------------------------------------------------------------+
//| Check if symbol is Gold                                          |
//+------------------------------------------------------------------+
bool IsGold() {
    string sym = _Symbol;
    StringToUpper(sym);
    return (StringFind(sym, "XAU") >= 0 || StringFind(sym, "GOLD") >= 0);
}

//+------------------------------------------------------------------+
//| Get pip size based on symbol - UNIVERSAL CALCULATION             |
//+------------------------------------------------------------------+
double GetPipSize() {
    // UNIVERSAL PIP SIZE CALCULATION
    // Gold: 2 or 3 decimals (pip = 0.01)
    // Forex: 4 or 5 decimals (pip = 0.0001)

    if(g_digits == 3 || g_digits == 2) {
        // Gold: 2 or 3 decimals
        return (g_digits == 3) ? g_point * 10 : g_point;  // 0.01
    }
    else if(g_digits == 5 || g_digits == 4) {
        // Forex: 4 or 5 decimals
        return (g_digits == 5) ? g_point * 10 : g_point;  // 0.0001
    }
    else {
        return g_point;  // Fallback
    }
}

//+------------------------------------------------------------------+
//| Convert price difference to pips                                 |
//+------------------------------------------------------------------+
double ToPips(double priceDiff) {
    if(g_pipSize <= 0) return 0;
    return MathAbs(priceDiff) / g_pipSize;
}

//+------------------------------------------------------------------+
//| Convert pips to price                                            |
//+------------------------------------------------------------------+
double ToPrice(double pips) {
    return pips * g_pipSize;
}

//+------------------------------------------------------------------+
//| Get current GMT hour from broker time                             |
//+------------------------------------------------------------------+
int GetGMTHour() {
    datetime serverTime = TimeCurrent();
    MqlDateTime dt;
    TimeToStruct(serverTime, dt);

    // Convert broker time to GMT (double-modulo ensures positive result)
    int gmtHour = ((dt.hour - BrokerGMTOffset) % 24 + 24) % 24;
    return gmtHour;
}

//+------------------------------------------------------------------+
//| Determine current trading session                                 |
//+------------------------------------------------------------------+
SESSION_TYPE GetCurrentSession() {
    int gmtHour = GetGMTHour();

    bool inAsian = (gmtHour >= AsianStartHour && gmtHour < AsianEndHour);
    bool inLondon = (gmtHour >= LondonStartHour && gmtHour < LondonEndHour);
    bool inNewYork = (gmtHour >= NewYorkStartHour && gmtHour < NewYorkEndHour);

    // Check for overlaps first
    if(inLondon && inNewYork) return SESSION_OVERLAP_LONDON_NY;
    if(inAsian && inLondon) return SESSION_OVERLAP_TOKYO_LONDON;

    // Single sessions
    if(inAsian) return SESSION_ASIAN;
    if(inLondon) return SESSION_LONDON;
    if(inNewYork) return SESSION_NEWYORK;

    return SESSION_NONE;
}

//+------------------------------------------------------------------+
//| Get session name for logging                                      |
//+------------------------------------------------------------------+
string GetSessionName(SESSION_TYPE session) {
    switch(session) {
        case SESSION_ASIAN: return "ASIAN";
        case SESSION_LONDON: return "LONDON";
        case SESSION_NEWYORK: return "NEW_YORK";
        case SESSION_OVERLAP_TOKYO_LONDON: return "TOKYO-LONDON_OVERLAP";
        case SESSION_OVERLAP_LONDON_NY: return "LONDON-NY_OVERLAP";
        default: return "OFF_HOURS";
    }
}

//+------------------------------------------------------------------+
//| Check if trading is allowed in current session                    |
//+------------------------------------------------------------------+
bool IsTradingAllowedInSession() {
    if(!EnableSessionFilter) return true;  // Filter disabled = always trade

    g_currentSession = GetCurrentSession();

    switch(g_currentSession) {
        case SESSION_ASIAN:
            return TradeAsianSession;
        case SESSION_LONDON:
            return TradeLondonSession;
        case SESSION_NEWYORK:
            return TradeNewYorkSession;
        case SESSION_OVERLAP_TOKYO_LONDON:
            return (TradeAsianSession || TradeLondonSession);
        case SESSION_OVERLAP_LONDON_NY:
            return (TradeLondonSession || TradeNewYorkSession);
        case SESSION_NONE:
        default:
            return false;  // No trading outside defined sessions
    }
}

//+------------------------------------------------------------------+
//| Calculate daily loss and profit limits based on settings          |
//+------------------------------------------------------------------+
void CalculateDailyLimits() {
    if(!EnableDailyLimits) {
        g_dailyMaxLoss = 0;
        g_dailyProfitGoal = 0;
        return;
    }

    // Calculate max daily loss (use larger of $ or %)
    double lossFromAmount = MaxDailyLossAmount;
    double lossFromPercent = g_dailyStartBalance * (MaxDailyLossPercent / 100.0);

    if(MaxDailyLossAmount > 0 && MaxDailyLossPercent > 0) {
        g_dailyMaxLoss = MathMax(lossFromAmount, lossFromPercent);
    } else if(MaxDailyLossAmount > 0) {
        g_dailyMaxLoss = lossFromAmount;
    } else if(MaxDailyLossPercent > 0) {
        g_dailyMaxLoss = lossFromPercent;
    } else {
        g_dailyMaxLoss = 0;  // No limit
    }

    // Calculate daily profit target (use larger of $ or %)
    double profitFromAmount = DailyProfitTarget;
    double profitFromPercent = g_dailyStartBalance * (DailyProfitPercent / 100.0);

    if(DailyProfitTarget > 0 && DailyProfitPercent > 0) {
        g_dailyProfitGoal = MathMax(profitFromAmount, profitFromPercent);
    } else if(DailyProfitTarget > 0) {
        g_dailyProfitGoal = profitFromAmount;
    } else if(DailyProfitPercent > 0) {
        g_dailyProfitGoal = profitFromPercent;
    } else {
        g_dailyProfitGoal = 0;  // No target
    }
}

//+------------------------------------------------------------------+
//| Update daily P&L based on current balance                         |
//+------------------------------------------------------------------+
void UpdateDailyPnL() {
    // Calculate realized P&L from balance change since day start
    g_dailyPnL = account.Balance() - g_dailyStartBalance;
}

//+------------------------------------------------------------------+
//| Check if daily P&L limits have been reached                       |
//| Returns: true = trading allowed, false = limit reached            |
//+------------------------------------------------------------------+
bool CheckDailyLimits() {
    if(!EnableDailyLimits) return true;  // No limits = trading allowed

    UpdateDailyPnL();

    // Check max daily loss
    if(g_dailyMaxLoss > 0 && g_dailyPnL <= -g_dailyMaxLoss) {
        if(!g_dailyLossLimitHit) {
            g_dailyLossLimitHit = true;
            Log("!!! DAILY LOSS LIMIT REACHED !!!", "LIMIT");
            Log("Daily P&L: $" + DoubleToString(g_dailyPnL, 2) +
                " | Max Loss: $" + DoubleToString(g_dailyMaxLoss, 2), "LIMIT");
        }
        return false;  // Stop trading
    }

    // Check daily profit target (if enabled)
    if(StopOnProfitTarget && g_dailyProfitGoal > 0 && g_dailyPnL >= g_dailyProfitGoal) {
        if(!g_dailyProfitTargetHit) {
            g_dailyProfitTargetHit = true;
            Log("*** DAILY PROFIT TARGET REACHED ***", "TARGET");
            Log("Daily P&L: $" + DoubleToString(g_dailyPnL, 2) +
                " | Target: $" + DoubleToString(g_dailyProfitGoal, 2), "TARGET");
        }
        return false;  // Stop trading
    }

    return true;  // Trading allowed
}

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit() {
    Log("========================================", "INIT");
    Log("Engulfing Trend ATR Bot v1.2 Starting", "INIT");
    Log("TRIPLE SL METHOD | 1:2 RR | Breakeven at 1:1 | Session Filter", "INIT");
    Log("SL = MAX of: ATR x 1.5, Wick + Clearance, 50% Body", "INIT");

    // Setup trade class
    trade.SetExpertMagicNumber(MagicNumber);
    trade.SetDeviationInPoints(Slippage);
    trade.SetTypeFilling(ORDER_FILLING_IOC);

    // Validate symbol
    if(!IsSymbolAllowed()) {
        Alert("This EA only works on XAUUSD or GBPUSD! Current: " + _Symbol);
        return INIT_FAILED;
    }

    // Get symbol specifications
    g_digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    g_point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    g_minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    g_maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    g_lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

    // Calculate pip size and value
    g_pipSize = GetPipSize();
    double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    if(tickSize > 0) {
        g_pipValue = tickValue * (g_pipSize / tickSize);
    }

    //--- AUTO-CALCULATE SYMBOL-SPECIFIC PARAMETERS ---
    if(IsGold()) {
        // GOLD: More lenient parameters for higher volatility
        g_activeMaxSpread = 35.0;        // Gold spread can be 1.6-2.5 pips typically, allow up to 35
        g_activeMinBody = 5.0;           // Min 5 pips body for Gold engulfing
        g_activeMaxATR = 1500.0;         // Gold ATR x 1.5 can be 900-1500 pips in volatile sessions
        g_activeTolerance = 5.0;         // More tolerance for engulfing matching
        g_activeBreakevenBuffer = 3.0;   // Wider buffer for Gold
        Log("GOLD MODE: Using lenient parameters for high volatility", "CONFIG");
    } else {
        // FOREX (GBPUSD): Tighter parameters for lower volatility
        g_activeMaxSpread = 5.0;         // Forex spread typically 0.3-1.0 pips
        g_activeMinBody = 3.0;           // Min 3 pips body for Forex engulfing
        g_activeMaxATR = 100.0;          // Forex ATR typically 30-80 pips
        g_activeTolerance = 2.0;         // Tighter tolerance for Forex
        g_activeBreakevenBuffer = 0.5;   // Tighter buffer for Forex
        Log("FOREX MODE: Using tight parameters for lower volatility", "CONFIG");
    }

    //--- PIP VALUE VERIFICATION ---
    Log("=== SYMBOL SPECIFICATIONS ===", "VERIFY");
    Log("Symbol: " + _Symbol + " (" + (IsGold() ? "GOLD" : "FOREX") + ")", "VERIFY");
    Log("Digits: " + IntegerToString(g_digits) + " | Point: " + DoubleToString(g_point, g_digits), "VERIFY");
    Log("Tick Size: " + DoubleToString(tickSize, g_digits) + " | Tick Value: $" + DoubleToString(tickValue, 4), "VERIFY");
    Log("Pip Size: " + DoubleToString(g_pipSize, g_digits) + " (" + (IsGold() ? "$0.01 move" : "0.0001 move") + ")", "VERIFY");
    Log("Pip Value: $" + DoubleToString(g_pipValue, 4) + " per pip per lot", "VERIFY");

    // Verify pip value is in expected range
    if(IsGold()) {
        // Gold: pip value should be ~$1.00 per lot (Exness standard)
        if(g_pipValue < 0.5 || g_pipValue > 2.0) {
            Log("WARNING: Gold pip value $" + DoubleToString(g_pipValue, 4) + " outside expected range!", "WARN");
            Log("Expected: ~$1.00 per pip per lot for XAUUSD on Exness", "WARN");
        } else {
            Log("VERIFIED: Gold pip value is within expected range", "VERIFY");
        }
    } else {
        // GBPUSD: pip value should be ~$10.00 per lot (Exness standard)
        if(g_pipValue < 8.0 || g_pipValue > 12.0) {
            Log("WARNING: GBPUSD pip value $" + DoubleToString(g_pipValue, 4) + " outside expected range!", "WARN");
            Log("Expected: ~$10.00 per pip per lot for GBPUSD on Exness", "WARN");
        } else {
            Log("VERIFIED: GBPUSD pip value is within expected range", "VERIFY");
        }
    }

    Log("=== ACTIVE PARAMETERS ===", "CONFIG");
    Log("Max Spread: " + DoubleToString(g_activeMaxSpread, 1) + " pips", "CONFIG");
    Log("Min Body: " + DoubleToString(g_activeMinBody, 1) + " pips", "CONFIG");
    Log("Max ATR SL: " + DoubleToString(g_activeMaxATR, 1) + " pips", "CONFIG");
    Log("Tolerance: " + DoubleToString(g_activeTolerance, 1) + " pips", "CONFIG");
    Log("BE Buffer: " + DoubleToString(g_activeBreakevenBuffer, 1) + " pips", "CONFIG");

    // Create ATR indicator handle
    g_atrHandle = iATR(_Symbol, PERIOD_CURRENT, ATR_Period);
    if(g_atrHandle == INVALID_HANDLE) {
        Log("FAILED to create ATR indicator!", "ERROR");
        return INIT_FAILED;
    }

    // Create Fast EMA handle
    g_emaFastHandle = iMA(_Symbol, PERIOD_CURRENT, EMA_Fast_Period, 0, MODE_EMA, EMA_Price);
    if(g_emaFastHandle == INVALID_HANDLE) {
        Log("FAILED to create Fast EMA indicator!", "ERROR");
        return INIT_FAILED;
    }

    // Create Slow EMA handle
    g_emaSlowHandle = iMA(_Symbol, PERIOD_CURRENT, EMA_Slow_Period, 0, MODE_EMA, EMA_Price);
    if(g_emaSlowHandle == INVALID_HANDLE) {
        Log("FAILED to create Slow EMA indicator!", "ERROR");
        return INIT_FAILED;
    }

    // Initialize state
    g_lastBarTime = 0;
    g_dailyTrades = 0;
    g_dailyResetTime = TimeCurrent();

    // Initialize daily P&L tracking
    g_dailyStartBalance = account.Balance();
    g_dailyPnL = 0;
    g_dailyLossLimitHit = false;
    g_dailyProfitTargetHit = false;
    CalculateDailyLimits();

    // Log final settings summary
    Log("========================================", "INIT");
    Log("Symbol: " + _Symbol + " (" + (IsGold() ? "GOLD" : "FOREX") + ") | TF: " + EnumToString((ENUM_TIMEFRAMES)_Period), "INIT");
    Log("ATR Period: " + IntegerToString(ATR_Period) + " | ATR Mult: " + DoubleToString(ATR_Multiplier, 1), "INIT");
    Log("EMA Fast: " + IntegerToString(EMA_Fast_Period) + " | EMA Slow: " + IntegerToString(EMA_Slow_Period), "INIT");
    Log("Risk: " + (UseFixedRisk ?
        "FIXED $" + DoubleToString(FixedRiskAmount, 2) :
        DoubleToString(RiskPercent, 1) + "% of balance") +
        " | RR: 1:" + DoubleToString(RiskRewardRatio, 1), "INIT");
    Log("Breakeven: " + (EnableBreakeven ? "ON at 1:1 (buffer: " + DoubleToString(g_activeBreakevenBuffer, 1) + " pips)" : "OFF"), "INIT");
    Log("========================================", "INIT");

    // Log session configuration
    if(EnableSessionFilter) {
        Log("=== SESSION FILTER ENABLED ===", "INIT");
        Log("Broker GMT Offset: GMT+" + IntegerToString(BrokerGMTOffset), "INIT");
        Log("Asian Session: " + (TradeAsianSession ? "ON" : "OFF") +
            " (" + IntegerToString(AsianStartHour) + ":00 - " +
            IntegerToString(AsianEndHour) + ":00 GMT)", "INIT");
        Log("London Session: " + (TradeLondonSession ? "ON" : "OFF") +
            " (" + IntegerToString(LondonStartHour) + ":00 - " +
            IntegerToString(LondonEndHour) + ":00 GMT)", "INIT");
        Log("New York Session: " + (TradeNewYorkSession ? "ON" : "OFF") +
            " (" + IntegerToString(NewYorkStartHour) + ":00 - " +
            IntegerToString(NewYorkEndHour) + ":00 GMT)", "INIT");

        g_currentSession = GetCurrentSession();
        Log("Current Session: " + GetSessionName(g_currentSession) +
            " | GMT Hour: " + IntegerToString(GetGMTHour()) +
            " | Trading Allowed: " + (IsTradingAllowedInSession() ? "YES" : "NO"), "INIT");
    } else {
        Log("Session filter: DISABLED (trading 24/5)", "INIT");
    }

    // Log daily P&L limits configuration
    if(EnableDailyLimits) {
        Log("=== DAILY P&L LIMITS ENABLED ===", "INIT");
        Log("Starting Balance: $" + DoubleToString(g_dailyStartBalance, 2), "INIT");
        Log("Max Daily Loss: $" + DoubleToString(g_dailyMaxLoss, 2) +
            " (" + DoubleToString(MaxDailyLossPercent, 1) + "% or $" +
            DoubleToString(MaxDailyLossAmount, 2) + ")", "INIT");
        Log("Daily Profit Target: $" + DoubleToString(g_dailyProfitGoal, 2) +
            " (" + DoubleToString(DailyProfitPercent, 1) + "% or $" +
            DoubleToString(DailyProfitTarget, 2) + ")", "INIT");
        Log("Stop on Profit Target: " + (StopOnProfitTarget ? "YES" : "NO"), "INIT");
    } else {
        Log("Daily P&L limits: DISABLED", "INIT");
    }

    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick() {
    if(!g_botEnabled) return;

    //--- ALWAYS manage breakeven on every tick (CRITICAL FEATURE)
    if(EnableBreakeven) {
        ManageBreakeven();
    }

    //--- Check for new bar
    datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
    if(currentBarTime == g_lastBarTime) return;
    g_lastBarTime = currentBarTime;

    //--- New bar processing
    OnNewBar();
}

//+------------------------------------------------------------------+
//| Daily reset check                                                |
//+------------------------------------------------------------------+
void CheckDailyReset() {
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);

    MqlDateTime resetDt;
    TimeToStruct(g_dailyResetTime, resetDt);

    if(resetDt.day_of_year != dt.day_of_year) {
        // Reset trade counter
        g_dailyTrades = 0;
        g_dailyResetTime = TimeCurrent();

        // Reset P&L tracking
        g_dailyStartBalance = account.Balance();
        g_dailyPnL = 0;
        g_dailyLossLimitHit = false;
        g_dailyProfitTargetHit = false;

        // Recalculate daily limits based on new starting balance
        CalculateDailyLimits();

        Log("=== DAILY RESET ===", "RESET");
        Log("Starting Balance: $" + DoubleToString(g_dailyStartBalance, 2), "RESET");
        if(EnableDailyLimits) {
            Log("Max Daily Loss: $" + DoubleToString(g_dailyMaxLoss, 2), "RESET");
            Log("Daily Profit Target: $" + DoubleToString(g_dailyProfitGoal, 2), "RESET");
        }
    }
}

//+------------------------------------------------------------------+
//| New bar handler - SINGLE TRADE LOGIC                             |
//+------------------------------------------------------------------+
void OnNewBar() {
    Log("========== NEW BAR ==========", "BAR");

    // Daily reset check
    CheckDailyReset();

    // Check daily P&L limits
    if(!CheckDailyLimits()) {
        Log("BLOCKED: Daily limit active (Loss: " +
            (g_dailyLossLimitHit ? "YES" : "NO") +
            " | Profit: " + (g_dailyProfitTargetHit ? "YES" : "NO") + ")", "LIMIT");
        return;
    }

    // Check daily trade count limit
    if(MaxTradesPerDay > 0 && g_dailyTrades >= MaxTradesPerDay) {
        Log("BLOCKED: Daily limit reached (" + IntegerToString(g_dailyTrades) + "/" + IntegerToString(MaxTradesPerDay) + ")", "LIMIT");
        return;
    }

    // Check spread (using auto-calculated symbol-specific limit)
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double spreadPips = ToPips(ask - bid);
    if(spreadPips > g_activeMaxSpread) {
        Log("BLOCKED: Spread " + DoubleToString(spreadPips, 1) + " > " + DoubleToString(g_activeMaxSpread, 1) + " pips", "SPREAD");
        return;
    }

    // Check trading session
    if(!IsTradingAllowedInSession()) {
        Log("BLOCKED: Outside trading session (" + GetSessionName(g_currentSession) +
            " | GMT Hour: " + IntegerToString(GetGMTHour()) + ")", "SESSION");
        return;
    }
    Log("Session: " + GetSessionName(g_currentSession) + " | GMT Hour: " + IntegerToString(GetGMTHour()), "SESSION");

    // Check if we already have an open position (SINGLE TRADE ONLY)
    if(HasOpenPosition()) {
        Log("Position already open - waiting for exit", "POSITION");
        return;
    }

    // Get trend direction from EMAs
    int trend = GetTrendDirection();
    if(trend == 0) {
        Log("No clear trend - EMA crossover zone", "TREND");
        return;
    }

    Log("Trend: " + (trend == 1 ? "UPTREND (Fast > Slow)" : "DOWNTREND (Fast < Slow)"), "TREND");

    // Check for engulfing pattern WITH trend filter
    int signal = DetectEngulfingWithTrend(trend);

    if(signal != 0) {
        ExecuteTrade(signal);
    }
}

//+------------------------------------------------------------------+
//| Get Trend Direction from Dual EMAs + Price Position              |
//| Returns: 1 = Uptrend, -1 = Downtrend, 0 = No trend               |
//| ENHANCED: Now also checks price position relative to both MAs    |
//+------------------------------------------------------------------+
int GetTrendDirection() {
    double emaFast[], emaSlow[];
    ArraySetAsSeries(emaFast, true);
    ArraySetAsSeries(emaSlow, true);

    // Get EMA values at bar index 1 (last closed bar)
    if(CopyBuffer(g_emaFastHandle, 0, 1, 1, emaFast) < 1) {
        Log("Failed to get Fast EMA value", "ERROR");
        return 0;
    }

    if(CopyBuffer(g_emaSlowHandle, 0, 1, 1, emaSlow) < 1) {
        Log("Failed to get Slow EMA value", "ERROR");
        return 0;
    }

    // Get current close price (of the completed candle)
    double currentPrice = iClose(_Symbol, PERIOD_CURRENT, 1);

    Log("Trend Check: Price=" + DoubleToString(currentPrice, g_digits) +
        " | EMA" + IntegerToString(EMA_Fast_Period) + "=" + DoubleToString(emaFast[0], g_digits) +
        " | EMA" + IntegerToString(EMA_Slow_Period) + "=" + DoubleToString(emaSlow[0], g_digits), "EMA");

    // UPTREND: Fast EMA > Slow EMA AND Price > both MAs
    if(emaFast[0] > emaSlow[0] && currentPrice > emaFast[0] && currentPrice > emaSlow[0]) {
        Log("UPTREND CONFIRMED: Price above both EMAs, Fast > Slow", "TREND");
        return 1;
    }

    // DOWNTREND: Fast EMA < Slow EMA AND Price < both MAs
    if(emaFast[0] < emaSlow[0] && currentPrice < emaFast[0] && currentPrice < emaSlow[0]) {
        Log("DOWNTREND CONFIRMED: Price below both EMAs, Fast < Slow", "TREND");
        return -1;
    }

    // Log why trend is not confirmed
    if(emaFast[0] > emaSlow[0]) {
        Log("No UPTREND: Fast > Slow but price not above both MAs", "TREND");
    } else if(emaFast[0] < emaSlow[0]) {
        Log("No DOWNTREND: Fast < Slow but price not below both MAs", "TREND");
    }

    return 0;  // No clear trend or mixed signals
}

//+------------------------------------------------------------------+
//| Detect Engulfing Pattern with Trend Filter                       |
//| Returns: 1 = Buy signal, -1 = Sell signal, 0 = No signal         |
//| UPDATED: Now stores candle data for Triple SL calculation        |
//+------------------------------------------------------------------+
int DetectEngulfingWithTrend(int trend) {
    // Reset engulfing data validity
    g_engulfing.isValid = false;

    // Get candle data (bar 2 = previous, bar 1 = current/just closed)
    double prevOpen  = iOpen(_Symbol, PERIOD_CURRENT, 2);
    double prevClose = iClose(_Symbol, PERIOD_CURRENT, 2);
    double currOpen  = iOpen(_Symbol, PERIOD_CURRENT, 1);
    double currClose = iClose(_Symbol, PERIOD_CURRENT, 1);
    double currHigh  = iHigh(_Symbol, PERIOD_CURRENT, 1);
    double currLow   = iLow(_Symbol, PERIOD_CURRENT, 1);

    // Calculate body sizes in pips
    double prevBodyPips = ToPips(prevClose - prevOpen);
    double currBodyPips = ToPips(currClose - currOpen);

    Log("Candle Analysis: Prev=" + DoubleToString(MathAbs(prevBodyPips), 1) + " pips | Curr=" + DoubleToString(MathAbs(currBodyPips), 1) + " pips", "CANDLE");

    // Minimum body size filter (using auto-calculated symbol-specific limit)
    if(MathAbs(currBodyPips) < g_activeMinBody || MathAbs(prevBodyPips) < g_activeMinBody) {
        Log("Body too small for engulfing (min: " + DoubleToString(g_activeMinBody, 1) + " pips)", "PATTERN");
        return 0;
    }

    // Candle directions
    bool prevBullish = (prevClose > prevOpen);
    bool currBullish = (currClose > currOpen);

    // Tolerance for matching (using auto-calculated symbol-specific tolerance)
    double tol = ToPrice(g_activeTolerance);

    //--- BULLISH ENGULFING (only in UPTREND)
    if(trend == 1 && currBullish && !prevBullish) {
        bool closeEngulfs = (currClose >= prevOpen - tol);
        bool openEngulfs = (currOpen <= prevClose + tol);

        if(closeEngulfs && openEngulfs) {
            // Store engulfing candle data for SL calculations
            g_engulfing.open = currOpen;
            g_engulfing.high = currHigh;
            g_engulfing.low = currLow;
            g_engulfing.close = currClose;
            g_engulfing.time = iTime(_Symbol, PERIOD_CURRENT, 1);
            g_engulfing.isBullish = true;
            g_engulfing.isValid = true;

            Log(">>> BULLISH ENGULFING in UPTREND! <<<", "SIGNAL");
            Log("Engulfing Candle: O=" + DoubleToString(currOpen, g_digits) +
                " H=" + DoubleToString(currHigh, g_digits) +
                " L=" + DoubleToString(currLow, g_digits) +
                " C=" + DoubleToString(currClose, g_digits), "SIGNAL");
            return 1;
        }
    }

    //--- BEARISH ENGULFING (only in DOWNTREND)
    if(trend == -1 && !currBullish && prevBullish) {
        bool closeEngulfs = (currClose <= prevOpen + tol);
        bool openEngulfs = (currOpen >= prevClose - tol);

        if(closeEngulfs && openEngulfs) {
            // Store engulfing candle data for SL calculations
            g_engulfing.open = currOpen;
            g_engulfing.high = currHigh;
            g_engulfing.low = currLow;
            g_engulfing.close = currClose;
            g_engulfing.time = iTime(_Symbol, PERIOD_CURRENT, 1);
            g_engulfing.isBullish = false;
            g_engulfing.isValid = true;

            Log(">>> BEARISH ENGULFING in DOWNTREND! <<<", "SIGNAL");
            Log("Engulfing Candle: O=" + DoubleToString(currOpen, g_digits) +
                " H=" + DoubleToString(currHigh, g_digits) +
                " L=" + DoubleToString(currLow, g_digits) +
                " C=" + DoubleToString(currClose, g_digits), "SIGNAL");
            return -1;
        }
    }

    Log("No engulfing pattern aligned with trend", "PATTERN");
    return 0;
}

//+------------------------------------------------------------------+
//| Get ATR value for Stop Loss calculation                          |
//+------------------------------------------------------------------+
double GetATRValue() {
    double atr[];
    ArraySetAsSeries(atr, true);

    if(CopyBuffer(g_atrHandle, 0, 1, 1, atr) < 1) {
        Log("Failed to get ATR value", "ERROR");
        return 0;
    }

    return atr[0];
}

//+------------------------------------------------------------------+
//| Calculate LARGEST SL from 3 methods (TRIPLE SL METHOD)           |
//| Returns: SL price (not distance), and slDistance via reference   |
//| Method 1: ATR × Multiplier                                       |
//| Method 2: Wick + Clearance + Spread Buffer                       |
//| Method 3: 50% of Engulfing Body + Spread Buffer                  |
//+------------------------------------------------------------------+
double CalculateBestSL(bool isBuy, double &slDistance) {
    Log("=== TRIPLE SL CALCULATION ===", "SL");

    // Get current entry price
    double entry = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                         : SymbolInfoDouble(_Symbol, SYMBOL_BID);

    //--- METHOD 1: ATR × Multiplier ---
    double atrValue = GetATRValue();
    double atrSL;
    if(isBuy) {
        atrSL = entry - (atrValue * ATR_Multiplier);
    } else {
        atrSL = entry + (atrValue * ATR_Multiplier);
    }
    double atrPips = ToPips(MathAbs(entry - atrSL));
    Log("Method 1 (ATR x " + DoubleToString(ATR_Multiplier, 1) + "): " + DoubleToString(atrPips, 1) + " pips | SL=" + DoubleToString(atrSL, g_digits), "SL");

    //--- METHOD 2: Wick + Clearance ---
    double wickSL;
    if(isBuy) {
        // BUY: SL below the low wick
        wickSL = g_engulfing.low - ToPrice(WickClearancePips) - ToPrice(SpreadBufferPips);
    } else {
        // SELL: SL above the high wick
        wickSL = g_engulfing.high + ToPrice(WickClearancePips) + ToPrice(SpreadBufferPips);
    }
    double wickPips = ToPips(MathAbs(entry - wickSL));
    Log("Method 2 (Wick+" + IntegerToString(WickClearancePips) + "+" + IntegerToString(SpreadBufferPips) + "): " + DoubleToString(wickPips, 1) + " pips | SL=" + DoubleToString(wickSL, g_digits), "SL");

    //--- METHOD 3: 50% Body ---
    double midBody = (g_engulfing.open + g_engulfing.close) / 2.0;
    double bodySL;
    if(isBuy) {
        // BUY: SL at middle of body minus buffer
        bodySL = midBody - ToPrice(SpreadBufferPips);
    } else {
        // SELL: SL at middle of body plus buffer
        bodySL = midBody + ToPrice(SpreadBufferPips);
    }
    double bodyPips = ToPips(MathAbs(entry - bodySL));
    Log("Method 3 (50% Body): " + DoubleToString(bodyPips, 1) + " pips | SL=" + DoubleToString(bodySL, g_digits) + " | MidBody=" + DoubleToString(midBody, g_digits), "SL");

    //--- Select LARGEST SL (furthest from entry = most protection) ---
    double bestSL;
    string method;

    if(isBuy) {
        // For BUY: lowest SL price = largest distance (most protective)
        bestSL = MathMin(atrSL, MathMin(wickSL, bodySL));
        if(bestSL == atrSL) method = "ATR";
        else if(bestSL == wickSL) method = "WICK";
        else method = "50%BODY";
    } else {
        // For SELL: highest SL price = largest distance (most protective)
        bestSL = MathMax(atrSL, MathMax(wickSL, bodySL));
        if(bestSL == atrSL) method = "ATR";
        else if(bestSL == wickSL) method = "WICK";
        else method = "50%BODY";
    }

    // Calculate final distance and pips
    slDistance = MathAbs(entry - bestSL);
    double bestPips = ToPips(slDistance);

    Log(">>> BEST SL: " + method + " = " + DoubleToString(bestPips, 1) + " pips <<<", "SL");
    Log("=== END TRIPLE SL ===", "SL");

    return NormalizeDouble(bestSL, g_digits);
}

//+------------------------------------------------------------------+
//| Calculate lot size based on stop loss distance                    |
//| Supports: Fixed $ risk OR % of balance risk                       |
//+------------------------------------------------------------------+
double CalcLots(double slDistance) {
    Log("=== LOT CALCULATION ===", "LOTS");

    double balance = account.Balance();
    double riskMoney;
    double slPips = ToPips(slDistance);

    // Flexible risk: fixed $ or % of balance
    if(UseFixedRisk) {
        riskMoney = FixedRiskAmount;
        Log("Using FIXED risk: $" + DoubleToString(riskMoney, 2), "LOTS");
    } else {
        riskMoney = balance * (RiskPercent / 100.0);
        Log("Using % risk: $" + DoubleToString(riskMoney, 2) +
            " (" + DoubleToString(RiskPercent, 1) + "% of $" +
            DoubleToString(balance, 2) + ")", "LOTS");
    }

    Log("SL Distance: " + DoubleToString(slPips, 1) + " pips", "LOTS");

    if(slPips <= 0 || g_pipValue <= 0) {
        Log("ERROR: Invalid SL (" + DoubleToString(slPips, 1) + ") or pip value (" + DoubleToString(g_pipValue, 2) + ")", "LOTS");
        return g_minLot;
    }

    // Lot size = Risk $ / (SL pips x pip value per lot)
    double lots = riskMoney / (slPips * g_pipValue);
    Log("Raw lots: " + DoubleToString(lots, 4), "LOTS");

    // Round DOWN to lot step
    lots = MathFloor(lots / g_lotStep) * g_lotStep;

    // Apply min/max
    lots = MathMax(lots, g_minLot);
    lots = MathMin(lots, g_maxLot);

    // Verify margin
    double marginReq = 0;
    if(OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, lots, SymbolInfoDouble(_Symbol, SYMBOL_ASK), marginReq)) {
        if(marginReq > account.FreeMargin() * 0.8) {
            Log("Reducing lots due to margin constraint", "LOTS");
            lots = g_minLot;
        }
    }

    double actualRisk = lots * slPips * g_pipValue;
    Log("FINAL: " + DoubleToString(lots, 2) + " lots | Actual Risk: $" + DoubleToString(actualRisk, 2), "LOTS");

    return NormalizeDouble(lots, 2);
}

//+------------------------------------------------------------------+
//| Execute Trade with TRIPLE SL METHOD and 1:2 RR TP                |
//| UPDATED: Now uses CalculateBestSL() for largest of 3 SL methods  |
//+------------------------------------------------------------------+
void ExecuteTrade(int signal) {
    Log("==========================================", "TRADE");
    Log(">>> EXECUTING SINGLE TRADE (TRIPLE SL METHOD) <<<", "TRADE");

    bool isBuy = (signal == 1);

    //--- Verify engulfing data is valid
    if(!g_engulfing.isValid) {
        Log("ABORT: Engulfing candle data not valid", "ERROR");
        return;
    }

    //--- Calculate BEST SL from 3 methods (ATR, Wick, 50% Body)
    double slDistance = 0;
    double sl = CalculateBestSL(isBuy, slDistance);

    if(slDistance <= 0) {
        Log("ABORT: Invalid SL distance calculated", "ERROR");
        return;
    }

    double slPips = ToPips(slDistance);

    //--- Check max SL limit (using auto-calculated symbol-specific limit)
    if(slPips > g_activeMaxATR) {
        Log("ABORT: SL " + DoubleToString(slPips, 1) + " > Max " + DoubleToString(g_activeMaxATR, 1) + " pips", "REJECT");
        return;
    }

    //--- Calculate TP distance = SL x RR Ratio (1:2)
    double tpDistance = slDistance * RiskRewardRatio;
    double tpPips = ToPips(tpDistance);

    Log("TP Distance: " + DoubleToString(tpPips, 1) + " pips (1:" + DoubleToString(RiskRewardRatio, 1) + " RR)", "TP");

    //--- Calculate lot size based on SL distance
    double lots = CalcLots(slDistance);
    if(lots < g_minLot) {
        Log("ABORT: Lot size too small", "TRADE");
        return;
    }

    //--- Get current prices
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

    double entry, tp;
    string action, comment;

    if(isBuy) {  // BUY
        entry = ask;
        tp = NormalizeDouble(entry + tpDistance, g_digits);
        action = "BUY";
        comment = "EngulfTripleSL_Buy";

        Log("BUY Setup: Entry=" + DoubleToString(entry, g_digits) +
            " | SL=" + DoubleToString(sl, g_digits) + " (" + DoubleToString(slPips, 1) + " pips)" +
            " | TP=" + DoubleToString(tp, g_digits) + " (" + DoubleToString(tpPips, 1) + " pips)", "TRADE");

    } else {  // SELL
        entry = bid;
        tp = NormalizeDouble(entry - tpDistance, g_digits);
        action = "SELL";
        comment = "EngulfTripleSL_Sell";

        Log("SELL Setup: Entry=" + DoubleToString(entry, g_digits) +
            " | SL=" + DoubleToString(sl, g_digits) + " (" + DoubleToString(slPips, 1) + " pips)" +
            " | TP=" + DoubleToString(tp, g_digits) + " (" + DoubleToString(tpPips, 1) + " pips)", "TRADE");
    }

    //--- Execute trade WITH TP
    bool success = false;
    if(isBuy) {
        success = trade.Buy(lots, _Symbol, entry, sl, tp, comment);
    } else {
        success = trade.Sell(lots, _Symbol, entry, sl, tp, comment);
    }

    if(success) {
        g_dailyTrades++;

        Log(">>> TRADE EXECUTED SUCCESSFULLY! <<<", "SUCCESS");
        Log("Ticket: " + IntegerToString((int)trade.ResultOrder()) +
            " | Lots: " + DoubleToString(lots, 2) +
            " | SL: " + DoubleToString(slPips, 1) + " pips" +
            " | TP: " + DoubleToString(tpPips, 1) + " pips", "SUCCESS");
    } else {
        Log("TRADE FAILED: " + trade.ResultRetcodeDescription(), "ERROR");
    }

    Log("==========================================", "TRADE");
}

//+------------------------------------------------------------------+
//| Manage Breakeven - Move SL to entry when profit reaches 1:1      |
//| THIS IS A NEW FEATURE NOT IN EXISTING BOTS                       |
//| Called on EVERY TICK for real-time management                    |
//+------------------------------------------------------------------+
void ManageBreakeven() {
    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if(ticket == 0) continue;

        if(!PositionSelectByTicket(ticket)) continue;

        // Check if this is our position
        if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
        if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

        double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
        double currentSL = PositionGetDouble(POSITION_SL);
        double currentTP = PositionGetDouble(POSITION_TP);
        long   posType   = PositionGetInteger(POSITION_TYPE);

        // Calculate original SL distance (since TP = RR x SL, SL = TP distance / RR)
        double tpDistance = MathAbs(currentTP - openPrice);
        double slDistance = tpDistance / RiskRewardRatio;  // Original SL distance

        // Check if already at breakeven (SL near entry)
        double beThreshold = ToPrice(g_activeBreakevenBuffer + 1.0);  // 1 pip tolerance
        if(MathAbs(currentSL - openPrice) < beThreshold) {
            continue;  // Already at breakeven
        }

        // Get current market price
        double currentPrice = (posType == POSITION_TYPE_BUY)
                              ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                              : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

        // Calculate current profit distance
        double profitDistance = (posType == POSITION_TYPE_BUY)
                                ? currentPrice - openPrice
                                : openPrice - currentPrice;

        // If profit >= 1:1 (original SL distance), move to breakeven
        if(profitDistance >= slDistance) {
            // Calculate breakeven price with buffer (using auto-calculated symbol-specific buffer)
            double bePrice;
            if(posType == POSITION_TYPE_BUY) {
                bePrice = openPrice + ToPrice(g_activeBreakevenBuffer);  // Buffer above entry
            } else {
                bePrice = openPrice - ToPrice(g_activeBreakevenBuffer);  // Buffer below entry
            }
            bePrice = NormalizeDouble(bePrice, g_digits);

            // Modify position SL to breakeven
            if(trade.PositionModify(ticket, bePrice, currentTP)) {
                Log(">>> BREAKEVEN ACTIVATED! <<<", "BE");
                Log("Ticket: " + IntegerToString((int)ticket) +
                    " | Old SL: " + DoubleToString(currentSL, g_digits) +
                    " | New SL: " + DoubleToString(bePrice, g_digits) +
                    " | Profit locked: " + DoubleToString(ToPips(profitDistance), 1) + " pips", "BE");
            } else {
                Log("Breakeven modify failed: " + trade.ResultRetcodeDescription(), "ERROR");
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Check if we have an open position (for single trade logic)       |
//+------------------------------------------------------------------+
bool HasOpenPosition() {
    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if(ticket == 0) continue;

        if(!PositionSelectByTicket(ticket)) continue;

        if(PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
           PositionGetString(POSITION_SYMBOL) == _Symbol) {
            return true;
        }
    }
    return false;
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
    // Release indicator handles
    if(g_atrHandle != INVALID_HANDLE)
        IndicatorRelease(g_atrHandle);
    if(g_emaFastHandle != INVALID_HANDLE)
        IndicatorRelease(g_emaFastHandle);
    if(g_emaSlowHandle != INVALID_HANDLE)
        IndicatorRelease(g_emaSlowHandle);

    Log("========================================", "DEINIT");
    Log("Bot stopped. Daily trades: " + IntegerToString(g_dailyTrades), "DEINIT");
    Log("Reason: " + IntegerToString(reason), "DEINIT");
    Log("========================================", "DEINIT");
}
//+------------------------------------------------------------------+
