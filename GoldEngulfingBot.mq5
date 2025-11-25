//+------------------------------------------------------------------+
//|                                           GoldEngulfingBot.mq5   |
//|                                  FXBot Gold Engulfing Strategy   |
//|                                           https://fxbot.trading  |
//+------------------------------------------------------------------+
#property copyright "FXBot Trading Platform"
#property link      "https://fxbot.trading"
#property version   "2.20"
#property strict

// Include necessary libraries
#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Trade\SymbolInfo.mqh>

//+------------------------------------------------------------------+
//| Input Parameters                                                 |
//+------------------------------------------------------------------+
input group "=== Server Configuration ==="
input string   ServerURL = "https://fxbot-server-production.up.railway.app/api";  // Backend Server URL
input string   BotToken = "";                            // Bot Authentication Token (legacy - auto-fetched)
input int      MagicNumber = 10001;                      // Magic Number (Unique per user)

input group "=== Trading Configuration ==="
input double   RiskPercent = 1.0;                        // Risk per trade (%)
input double   MaxRiskPercent = 5.0;                     // Maximum risk allowed (%)
input int      WickClearance = 5;                        // Stop loss clearance in pips
input bool     EnableSecondTrade = true;                 // Enable second layer entry
input int      Slippage = 10;                            // Maximum slippage in points
input int      MaxStopLossPips = 100;                    // Maximum stop loss distance (pips)

input group "=== Exit Strategy ==="
input bool     UseTrailingStop = false;                  // Enable trailing stop (disabled for testing)
input int      TrailingStartPips = 15;                   // Start trailing after X pips profit
input int      TrailingStepPips = 5;                     // Trail by X pips
input bool     UseBreakEven = false;                     // Move SL to breakeven (disabled for testing)
input int      BreakEvenPips = 10;                       // Move to BE after X pips profit
input int      BreakEvenBufferPips = 1;                  // Buffer above breakeven (pips)
input bool     CloseOnReversal = true;                   // Close on opposite engulfing pattern

input group "=== Spread Protection ==="
input int      MaxSpread = 300;                          // Maximum spread in points (300 = 30 pips for Gold)

input group "=== Trade Limits ==="
input int      MaxTradesPerDay = 0;                      // Maximum trades per day (0 = unlimited)
input int      RestMinutesBetweenTrades = 0;             // Minutes between trades (0 = no rest)
input int      RestMinutesAfterLoss = 0;                 // Minutes rest after losing trade
input int      MaxConsecutiveLosses = 0;                 // Max losses before extended break (0 = disabled)
input int      ExtendedBreakMinutes = 0;                 // Break duration after max consecutive losses

input group "=== Risk Protection ==="
input double   MaxDailyDrawdownPercent = 0;              // Stop trading if down X% today (0 = disabled)

input group "=== Market Filters ==="
input bool     AvoidMondayOpen = true;                   // Skip first 2 hours Monday
input bool     AvoidFridayClose = false;                 // Skip last 3 hours Friday

input group "=== Connection Settings ==="
input int      HeartbeatInterval = 30;                   // Heartbeat interval (seconds)
input int      UpdateInterval = 5;                       // Position update interval (seconds)
input int      ConfigRefreshInterval = 300;              // Config refresh interval (seconds) - 5 min
input int      MaxRetries = 3;                           // Max retry attempts for requests

//+------------------------------------------------------------------+
//| Global Variables                                                 |
//+------------------------------------------------------------------+
CTrade trade;
CPositionInfo position;
CAccountInfo account;
CSymbolInfo symbolInfo;

// Symbol metrics (calculated once at init)
double g_pipSize = 0;
double g_pipValue = 0;
int g_digits = 0;

// Engulfing bar structure
struct EngulfingBar {
    double open;
    double high;
    double low;
    double close;
    datetime time;
    bool isBullish;
    bool isValid;
};

// Server-driven configuration structure
struct ServerConfig {
    // Trading
    double riskPercent;
    double maxRiskPercent;
    int wickClearance;
    bool enableSecondTrade;
    int slippage;
    int maxStopLossPips;

    // Exit Strategy
    bool useTrailingStop;
    int trailingStartPips;
    int trailingStepPips;
    bool useBreakEven;
    int breakEvenPips;
    int breakEvenBufferPips;
    bool closeOnReversal;

    // Guard Rails
    int maxSpread;
    int maxTradesPerDay;
    int restMinutesBetweenTrades;
    int restMinutesAfterLoss;
    int maxConsecutiveLosses;
    int extendedBreakMinutes;
    double maxDailyDrawdownPercent;

    // Market Filters
    bool avoidMondayOpen;
    bool avoidFridayClose;

    // Meta
    int configVersion;
    bool isLoaded;
};

// Global server config instance
ServerConfig serverConfig;
datetime lastConfigFetch = 0;

// Bot state
EngulfingBar currentEngulfing;
bool firstTradeOpen = false;
bool secondTradeOpen = false;
int lastSignalBar = -1;
datetime lastHeartbeat = 0;
datetime lastUpdate = 0;
bool botEnabled = true;
string sessionId = "";
string jwtToken = "";

// Trade tracking for trailing stop and break-even
ulong firstTradeTicket = 0;
ulong secondTradeTicket = 0;
double firstTradeEntryPrice = 0;
double secondTradeEntryPrice = 0;
int secondTradeBarCount = 0;
bool breakEvenApplied = false;

// Guard rail tracking
int dailyTradesCount = 0;
int consecutiveLosses = 0;
datetime lastTradeCloseTime = 0;
datetime dailyResetTime = 0;
double dailyStartingBalance = 0;
double lastClosedTradeProfit = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit() {
    // Initialize trading classes
    trade.SetExpertMagicNumber(MagicNumber);
    trade.SetDeviationInPoints(Slippage);
    trade.SetTypeFilling(ORDER_FILLING_IOC);

    // Validate symbol
    if(!symbolInfo.Name(_Symbol)) {
        Alert("Failed to initialize symbol: ", _Symbol);
        return INIT_FAILED;
    }

    // Check if gold symbol (accepts XAUUSD, XAUUSDm, XAUUSD., Gold, etc.)
    if(StringFind(_Symbol, "XAU", 0) < 0 && StringFind(_Symbol, "GOLD", 0) < 0) {
        Alert("This EA is designed for Gold (XAU/GOLD) symbols only! Current symbol: " + _Symbol);
        return INIT_FAILED;
    }

    // CRITICAL: Validate timeframe - H1, M15, and M1 (M1 for testing) allowed
    if(_Period != PERIOD_H1 && _Period != PERIOD_M15 && _Period != PERIOD_M1) {
        Alert("This EA works on H1, M15, and M1 timeframes!");
        Alert("Current timeframe: ", EnumToString((ENUM_TIMEFRAMES)_Period));
        return INIT_FAILED;
    }

    // Warn if using M1 (generates many signals - for testing only)
    if(_Period == PERIOD_M1) {
        Print("WARNING: M1 timeframe selected - signals will be frequent. Use small lot sizes for testing!");
    }

    // Initialize symbol metrics
    if(!InitializeSymbolMetrics()) {
        Alert("Failed to initialize symbol metrics!");
        return INIT_FAILED;
    }

    // Initialize daily tracking
    dailyStartingBalance = account.Balance();
    dailyResetTime = TimeCurrent();
    dailyTradesCount = 0;
    consecutiveLosses = 0;

    // Authenticate with server
    if(!AuthenticateBot()) {
        Alert("Failed to authenticate with server!");
        return INIT_FAILED;
    }

    // Fetch configuration from server (with fallback to input parameters)
    if(!FetchServerConfig()) {
        Print("Using fallback configuration from input parameters");
        LoadDefaultConfig();
    }

    Print("=== Gold Engulfing Bot v2.2 Initialized ===");
    Print("Symbol: ", _Symbol);
    Print("Timeframe: ", EnumToString((ENUM_TIMEFRAMES)_Period));
    Print("Server: ", ServerURL);
    Print("Magic Number: ", MagicNumber);
    Print("Config Source: ", serverConfig.isLoaded ? "Server (v" + IntegerToString(serverConfig.configVersion) + ")" : "Local Fallback");
    Print("Risk: ", GetConfigRiskPercent(), "%");
    Print("Pip Size: ", g_pipSize);
    Print("Pip Value per Lot: ", g_pipValue);
    Print("Max Spread: ", GetConfigMaxSpread(), " points");
    Print("Max Trades/Day: ", GetConfigMaxTradesPerDay());

    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Initialize symbol metrics for pip calculations                   |
//+------------------------------------------------------------------+
bool InitializeSymbolMetrics() {
    g_digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

    double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);

    if(tickSize <= 0 || tickValue <= 0) {
        Print("ERROR: Invalid tick size (", tickSize, ") or tick value (", tickValue, ")");
        return false;
    }

    // For gold: pip size is typically the tick size (0.01 or 0.001)
    g_pipSize = tickSize;

    // Pip value per standard lot
    g_pipValue = tickValue / tickSize;

    Print("Symbol Metrics - Digits: ", g_digits, " TickSize: ", tickSize,
          " TickValue: ", tickValue, " PipSize: ", g_pipSize, " PipValue: ", g_pipValue);

    return true;
}

//+------------------------------------------------------------------+
//| Get pip size for the symbol                                      |
//+------------------------------------------------------------------+
double GetPipSize() {
    return g_pipSize;
}

//+------------------------------------------------------------------+
//| Get pip value per lot                                            |
//+------------------------------------------------------------------+
double GetPipValuePerLot() {
    return g_pipValue;
}

//+------------------------------------------------------------------+
//| Convert price distance to pips                                   |
//+------------------------------------------------------------------+
double PriceToPips(double priceDistance) {
    if(g_pipSize <= 0) return 0;
    return MathAbs(priceDistance) / g_pipSize;
}

//+------------------------------------------------------------------+
//| Convert pips to price distance                                   |
//+------------------------------------------------------------------+
double PipsToPrice(double pips) {
    return pips * g_pipSize;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
    // Send disconnection notification
    SendDisconnectionNotice(reason);
    Print("Gold Engulfing Bot stopped. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick() {
    // Check if bot is enabled
    if(!botEnabled) return;

    // Reset daily counters if new day
    CheckDailyReset();

    // Send heartbeat
    if(TimeCurrent() - lastHeartbeat > HeartbeatInterval) {
        SendHeartbeat();
        lastHeartbeat = TimeCurrent();
    }

    // Send position updates
    if(TimeCurrent() - lastUpdate > UpdateInterval) {
        SendPositionUpdate();
        lastUpdate = TimeCurrent();
    }

    // Refresh server config periodically
    if(TimeCurrent() - lastConfigFetch > ConfigRefreshInterval) {
        FetchServerConfig();
    }

    // Check for new bar
    static datetime lastBarTime = 0;
    datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);

    if(lastBarTime != currentBarTime) {
        lastBarTime = currentBarTime;
        OnNewBar();
    }

    // Monitor existing trades (trailing stop, break-even, etc.)
    MonitorTrades();
}

//+------------------------------------------------------------------+
//| Check and reset daily counters                                   |
//+------------------------------------------------------------------+
void CheckDailyReset() {
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);

    // Reset at 21:00 GMT (approximate end of NY session)
    if(dt.hour == 21 && dt.min == 0) {
        MqlDateTime resetDt;
        TimeToStruct(dailyResetTime, resetDt);

        // Only reset once per day
        if(resetDt.day_of_year != dt.day_of_year) {
            dailyTradesCount = 0;
            consecutiveLosses = 0;
            dailyStartingBalance = account.Balance();
            dailyResetTime = TimeCurrent();
            Print("Daily counters reset. New starting balance: ", dailyStartingBalance);
        }
    }
}

//+------------------------------------------------------------------+
//| New bar event handler                                           |
//+------------------------------------------------------------------+
void OnNewBar() {
    // Run all pre-trade checks
    if(!CanOpenNewTrade()) return;

    // Check for engulfing pattern
    EngulfingBar bar;
    if(DetectEngulfingBar(bar) && !firstTradeOpen) {
        // Check for reversal exit on existing trades (if any)
        if(GetConfigCloseOnReversal() && secondTradeOpen) {
            CheckReversalExit(bar);
        }

        currentEngulfing = bar;
        ExecuteFirstTrade();
        lastSignalBar = iBars(_Symbol, PERIOD_CURRENT);
    }

    // Check for second trade condition
    if(firstTradeOpen && !secondTradeOpen && GetConfigEnableSecondTrade()) {
        CheckSecondTradeCondition();
    }
}

//+------------------------------------------------------------------+
//| Pre-trade validation - all guard rails                          |
//+------------------------------------------------------------------+
bool CanOpenNewTrade() {
    // Check spread
    if(!IsSpreadAcceptable()) {
        return false;
    }

    // Check daily trade limit
    int maxTrades = GetConfigMaxTradesPerDay();
    if(maxTrades > 0 && dailyTradesCount >= maxTrades) {
        return false;
    }

    // Check rest period between trades
    if(!IsRestPeriodComplete()) {
        return false;
    }

    // Check daily drawdown
    if(!IsDrawdownWithinLimit()) {
        return false;
    }

    // Check trading hours
    if(!IsWithinTradingHours()) {
        return false;
    }

    return true;
}

//+------------------------------------------------------------------+
//| Check if spread is acceptable                                    |
//+------------------------------------------------------------------+
bool IsSpreadAcceptable() {
    int spread = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
    int maxSpread = GetConfigMaxSpread();
    if(spread > maxSpread) {
        Print("Spread too high: ", spread, " points (max: ", maxSpread, ")");
        return false;
    }
    return true;
}

//+------------------------------------------------------------------+
//| Check if rest period between trades is complete                  |
//+------------------------------------------------------------------+
bool IsRestPeriodComplete() {
    if(lastTradeCloseTime == 0) return true;

    int minutesSinceLastTrade = (int)((TimeCurrent() - lastTradeCloseTime) / 60);

    // Extended break after consecutive losses
    int maxConsecLosses = GetConfigMaxConsecutiveLosses();
    if(maxConsecLosses > 0 && consecutiveLosses >= maxConsecLosses) {
        if(minutesSinceLastTrade < GetConfigExtendedBreakMinutes()) {
            return false;
        }
        // Reset consecutive losses after extended break
        consecutiveLosses = 0;
    }

    // Normal rest period
    int restBetween = GetConfigRestMinutesBetweenTrades();
    if(restBetween > 0 && minutesSinceLastTrade < restBetween) {
        return false;
    }

    // Extra rest after loss
    int restAfterLoss = GetConfigRestMinutesAfterLoss();
    if(lastClosedTradeProfit < 0 && restAfterLoss > 0) {
        if(minutesSinceLastTrade < restAfterLoss) {
            return false;
        }
    }

    return true;
}

//+------------------------------------------------------------------+
//| Check if daily drawdown is within limit                          |
//+------------------------------------------------------------------+
bool IsDrawdownWithinLimit() {
    double maxDDPercent = GetConfigMaxDailyDrawdownPercent();
    if(maxDDPercent <= 0) return true;

    double currentLoss = dailyStartingBalance - account.Balance();
    double maxLoss = dailyStartingBalance * (maxDDPercent / 100.0);

    if(currentLoss >= maxLoss) {
        Print("Daily drawdown limit reached. Loss: ", currentLoss, " Max: ", maxLoss);
        return false;
    }

    return true;
}

//+------------------------------------------------------------------+
//| Check if within trading hours                                    |
//+------------------------------------------------------------------+
bool IsWithinTradingHours() {
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);

    // Avoid Monday open (first 2 hours)
    if(GetConfigAvoidMondayOpen() && dt.day_of_week == 1 && dt.hour < 2) {
        return false;
    }

    // Avoid Friday close (last 3 hours before market close at ~22:00)
    if(GetConfigAvoidFridayClose() && dt.day_of_week == 5 && dt.hour >= 19) {
        return false;
    }

    return true;
}

//+------------------------------------------------------------------+
//| Detect engulfing bar pattern                                    |
//| Based on MQL5 best practices from official documentation        |
//| Reference: https://www.mql5.com/en/articles/12385               |
//+------------------------------------------------------------------+
bool DetectEngulfingBar(EngulfingBar &bar) {
    // Get previous candle data (shift 2 = candle before last)
    double prevOpen = iOpen(_Symbol, PERIOD_CURRENT, 2);
    double prevHigh = iHigh(_Symbol, PERIOD_CURRENT, 2);
    double prevLow = iLow(_Symbol, PERIOD_CURRENT, 2);
    double prevClose = iClose(_Symbol, PERIOD_CURRENT, 2);

    // Get current completed candle data (shift 1 = last closed candle)
    double currOpen = iOpen(_Symbol, PERIOD_CURRENT, 1);
    double currHigh = iHigh(_Symbol, PERIOD_CURRENT, 1);
    double currLow = iLow(_Symbol, PERIOD_CURRENT, 1);
    double currClose = iClose(_Symbol, PERIOD_CURRENT, 1);

    // Calculate body boundaries (direction-agnostic)
    double prevBodyHigh = MathMax(prevOpen, prevClose);
    double prevBodyLow = MathMin(prevOpen, prevClose);
    double currBodyHigh = MathMax(currOpen, currClose);
    double currBodyLow = MathMin(currOpen, currClose);

    // Calculate body sizes for minimum size filter
    double prevBodySize = prevBodyHigh - prevBodyLow;
    double currBodySize = currBodyHigh - currBodyLow;

    // Minimum body size check - avoid tiny engulfing patterns (noise)
    // Require at least 0.5 pips body size for Gold
    double minBodySize = PipsToPrice(0.5);
    if(currBodySize < minBodySize || prevBodySize < minBodySize) {
        return false;
    }

    // Determine candle directions
    bool currIsBullish = (currClose > currOpen);
    bool currIsBearish = (currClose < currOpen);
    bool prevIsBullish = (prevClose > prevOpen);
    bool prevIsBearish = (prevClose < prevOpen);

    // ==================== BULLISH ENGULFING ====================
    // Classic rules (MQL5 best practices):
    // 1. Current candle is bullish (close > open)
    // 2. Previous candle is bearish (for classic pattern) OR any direction (relaxed)
    // 3. Current body fully engulfs previous body
    // 4. For Forex (no gaps): use <= for body overlap instead of <
    bool bullishEngulfing = currIsBullish &&                    // Current is bullish
                            prevIsBearish &&                    // Previous is bearish (classic rule)
                            (currBodyLow <= prevBodyLow) &&     // Current body low <= previous body low
                            (currBodyHigh >= prevBodyHigh) &&   // Current body high >= previous body high
                            (currClose >= prevOpen) &&          // Close >= previous open (body overlap)
                            (currOpen <= prevClose);            // Open <= previous close (Forex-adjusted)

    // ==================== BEARISH ENGULFING ====================
    // Classic rules (MQL5 best practices):
    // 1. Current candle is bearish (close < open)
    // 2. Previous candle is bullish (for classic pattern) OR any direction (relaxed)
    // 3. Current body fully engulfs previous body
    // 4. For Forex (no gaps): use >= for body overlap instead of >
    bool bearishEngulfing = currIsBearish &&                    // Current is bearish
                            prevIsBullish &&                    // Previous is bullish (classic rule)
                            (currBodyLow <= prevBodyLow) &&     // Current body low <= previous body low
                            (currBodyHigh >= prevBodyHigh) &&   // Current body high >= previous body high
                            (currClose <= prevOpen) &&          // Close <= previous open (body overlap)
                            (currOpen >= prevClose);            // Open >= previous close (Forex-adjusted)

    // Fill bar structure if pattern detected
    if(bullishEngulfing || bearishEngulfing) {
        bar.open = currOpen;
        bar.high = currHigh;
        bar.low = currLow;
        bar.close = currClose;
        bar.time = iTime(_Symbol, PERIOD_CURRENT, 1);
        bar.isBullish = bullishEngulfing;
        bar.isValid = true;

        // Log pattern details
        Print("=== ENGULFING PATTERN DETECTED ===");
        Print("Type: ", bullishEngulfing ? "BULLISH" : "BEARISH");
        Print("Prev Candle: O=", prevOpen, " H=", prevHigh, " L=", prevLow, " C=", prevClose);
        Print("Curr Candle: O=", currOpen, " H=", currHigh, " L=", currLow, " C=", currClose);
        Print("Prev Body: ", prevBodyLow, " - ", prevBodyHigh, " (size: ", PriceToPips(prevBodySize), " pips)");
        Print("Curr Body: ", currBodyLow, " - ", currBodyHigh, " (size: ", PriceToPips(currBodySize), " pips)");

        // Validate stop loss distance isn't too large
        int wickClear = GetConfigWickClearance();
        double slDistance = bar.isBullish ?
            PriceToPips(currClose - currLow + PipsToPrice(wickClear)) :
            PriceToPips(currHigh - currClose + PipsToPrice(wickClear));

        if(slDistance > GetConfigMaxStopLossPips()) {
            Print("Engulfing bar rejected - SL distance too large: ", slDistance, " pips (max: ", GetConfigMaxStopLossPips(), ")");
            return false;
        }

        Print("SL Distance: ", slDistance, " pips (valid)");

        // Send signal to server
        SendSignalNotification(bar);

        return true;
    }

    return false;
}

//+------------------------------------------------------------------+
//| Check for reversal pattern to exit early                         |
//+------------------------------------------------------------------+
void CheckReversalExit(EngulfingBar &newBar) {
    // If we're in a bullish trade and bearish engulfing appears, close
    if(currentEngulfing.isBullish && !newBar.isBullish) {
        Print("Reversal detected - closing bullish positions");
        CloseTradesByComment("Gold Engulfing Buy #2");
        secondTradeOpen = false;
        ResetTradingState();
    }
    // If we're in a bearish trade and bullish engulfing appears, close
    else if(!currentEngulfing.isBullish && newBar.isBullish) {
        Print("Reversal detected - closing bearish positions");
        CloseTradesByComment("Gold Engulfing Sell #2");
        secondTradeOpen = false;
        ResetTradingState();
    }
}

//+------------------------------------------------------------------+
//| Execute first trade based on engulfing pattern                  |
//+------------------------------------------------------------------+
void ExecuteFirstTrade() {
    if(!currentEngulfing.isValid) return;

    // Final spread check before execution
    if(!IsSpreadAcceptable()) return;

    double entryPrice, stopLoss;

    int wickClear = GetConfigWickClearance();
    if(currentEngulfing.isBullish) {
        entryPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        stopLoss = currentEngulfing.low - PipsToPrice(wickClear);
    } else {
        entryPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        stopLoss = currentEngulfing.high + PipsToPrice(wickClear);
    }

    // Calculate lot size based on actual SL distance
    double slDistancePips = PriceToPips(MathAbs(entryPrice - stopLoss));
    double lotSize = CalculateLotSize(slDistancePips);

    if(lotSize <= 0) {
        Print("Invalid lot size calculated");
        return;
    }

    // Execute trade with retry
    bool success = false;
    string comment = currentEngulfing.isBullish ? "Gold Engulfing Buy #1" : "Gold Engulfing Sell #1";

    if(currentEngulfing.isBullish) {
        success = ExecuteTradeWithRetry(ORDER_TYPE_BUY, lotSize, entryPrice, stopLoss, 0, comment);
    } else {
        success = ExecuteTradeWithRetry(ORDER_TYPE_SELL, lotSize, entryPrice, stopLoss, 0, comment);
    }

    if(success) {
        firstTradeOpen = true;
        firstTradeTicket = trade.ResultOrder();
        firstTradeEntryPrice = entryPrice;
        breakEvenApplied = false;
        dailyTradesCount++;
        Print("First trade opened. Ticket: ", firstTradeTicket, " Entry: ", entryPrice, " SL: ", stopLoss);
        SendTradeNotification(currentEngulfing.isBullish ? "BUY" : "SELL", lotSize, entryPrice, stopLoss);
    }
}

//+------------------------------------------------------------------+
//| Check condition for second trade                                |
//+------------------------------------------------------------------+
void CheckSecondTradeCondition() {
    // Get the last closed bar (index 1)
    double lastOpen = iOpen(_Symbol, PERIOD_CURRENT, 1);
    double lastClose = iClose(_Symbol, PERIOD_CURRENT, 1);
    double lastHigh = iHigh(_Symbol, PERIOD_CURRENT, 1);
    double lastLow = iLow(_Symbol, PERIOD_CURRENT, 1);

    bool sameDirection = false;

    if(currentEngulfing.isBullish) {
        sameDirection = (lastClose > lastOpen);
    } else {
        sameDirection = (lastClose < lastOpen);
    }

    // Close first trade
    CloseTradesByComment("Gold Engulfing Buy #1");
    CloseTradesByComment("Gold Engulfing Sell #1");
    firstTradeOpen = false;

    // Track trade result
    UpdateTradeStats();

    if(sameDirection && GetConfigEnableSecondTrade() && CanOpenNewTrade()) {
        ExecuteSecondTrade(lastLow, lastHigh);
    } else {
        ResetTradingState();
    }
}

//+------------------------------------------------------------------+
//| Execute second trade                                            |
//+------------------------------------------------------------------+
void ExecuteSecondTrade(double lastLow, double lastHigh) {
    // Final spread check
    if(!IsSpreadAcceptable()) {
        ResetTradingState();
        return;
    }

    double entryPrice, stopLoss;

    if(currentEngulfing.isBullish) {
        entryPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        stopLoss = lastLow - PipsToPrice(GetConfigWickClearance());
    } else {
        entryPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        stopLoss = lastHigh + PipsToPrice(GetConfigWickClearance());
    }

    // Calculate lot size based on actual SL distance
    double slDistancePips = PriceToPips(MathAbs(entryPrice - stopLoss));
    double lotSize = CalculateLotSize(slDistancePips);

    if(lotSize <= 0) {
        Print("Invalid lot size for second trade");
        ResetTradingState();
        return;
    }

    string comment = currentEngulfing.isBullish ? "Gold Engulfing Buy #2" : "Gold Engulfing Sell #2";
    bool success = false;

    if(currentEngulfing.isBullish) {
        success = ExecuteTradeWithRetry(ORDER_TYPE_BUY, lotSize, entryPrice, stopLoss, 0, comment);
    } else {
        success = ExecuteTradeWithRetry(ORDER_TYPE_SELL, lotSize, entryPrice, stopLoss, 0, comment);
    }

    if(success) {
        secondTradeOpen = true;
        secondTradeTicket = trade.ResultOrder();
        secondTradeEntryPrice = entryPrice;
        secondTradeBarCount = 0;
        breakEvenApplied = false;
        dailyTradesCount++;
        Print("Second trade opened. Ticket: ", secondTradeTicket, " Entry: ", entryPrice, " SL: ", stopLoss);
        SendTradeNotification(currentEngulfing.isBullish ? "BUY" : "SELL", lotSize, entryPrice, stopLoss);
    } else {
        ResetTradingState();
    }
}

//+------------------------------------------------------------------+
//| Execute trade with retry logic                                   |
//+------------------------------------------------------------------+
bool ExecuteTradeWithRetry(ENUM_ORDER_TYPE orderType, double lotSize,
                           double price, double sl, double tp, string comment) {
    for(int attempt = 0; attempt < MaxRetries; attempt++) {
        // Refresh prices
        double currentPrice = (orderType == ORDER_TYPE_BUY) ?
            SymbolInfoDouble(_Symbol, SYMBOL_ASK) :
            SymbolInfoDouble(_Symbol, SYMBOL_BID);

        bool result = false;

        if(orderType == ORDER_TYPE_BUY) {
            result = trade.Buy(lotSize, _Symbol, currentPrice, sl, tp, comment);
        } else {
            result = trade.Sell(lotSize, _Symbol, currentPrice, sl, tp, comment);
        }

        if(result) {
            return true;
        }

        uint retcode = trade.ResultRetcode();
        Print("Trade attempt ", attempt + 1, " failed. Retcode: ", retcode);

        // Check if error is retryable (MQL5 trade return codes)
        if(retcode == TRADE_RETCODE_REQUOTE ||      // 10004
           retcode == TRADE_RETCODE_PRICE_CHANGED || // 10013
           retcode == TRADE_RETCODE_PRICE_OFF ||     // 10021
           retcode == TRADE_RETCODE_TIMEOUT ||       // 10012
           retcode == TRADE_RETCODE_CONNECTION) {    // 10031
            Sleep(500 * (attempt + 1)); // Exponential backoff
            continue;
        }

        // Non-retryable error
        break;
    }

    return false;
}

//+------------------------------------------------------------------+
//| Monitor and manage open trades                                  |
//+------------------------------------------------------------------+
void MonitorTrades() {
    // Monitor second trade
    if(secondTradeOpen) {
        // Apply break-even if enabled
        if(GetConfigUseBreakEven() && !breakEvenApplied) {
            ApplyBreakEven();
        }

        // Apply trailing stop if enabled
        if(GetConfigUseTrailingStop()) {
            ApplyTrailingStop();
        }

        // Track bar count for second trade
        static datetime lastSecondTradeBar = 0;
        datetime currentBar = iTime(_Symbol, PERIOD_CURRENT, 0);

        if(lastSecondTradeBar != currentBar) {
            if(lastSecondTradeBar != 0) {
                secondTradeBarCount++;
            }
            lastSecondTradeBar = currentBar;
        }

        // Close after one complete bar
        if(secondTradeBarCount >= 1) {
            Print("Closing second trade after ", secondTradeBarCount, " bar(s)");
            CloseTradesByComment("Gold Engulfing Buy #2");
            CloseTradesByComment("Gold Engulfing Sell #2");
            secondTradeOpen = false;
            lastSecondTradeBar = 0;
            UpdateTradeStats();
            ResetTradingState();
        }
    }
}

//+------------------------------------------------------------------+
//| Apply break-even stop loss                                       |
//+------------------------------------------------------------------+
void ApplyBreakEven() {
    if(!secondTradeOpen || secondTradeTicket == 0) return;

    if(!position.SelectByTicket(secondTradeTicket)) return;

    double entryPrice = position.PriceOpen();
    double currentPrice = position.PriceCurrent();
    double currentSL = position.StopLoss();

    bool isBuy = (position.PositionType() == POSITION_TYPE_BUY);
    double profitPips = isBuy ?
        PriceToPips(currentPrice - entryPrice) :
        PriceToPips(entryPrice - currentPrice);

    if(profitPips >= GetConfigBreakEvenPips()) {
        double newSL = isBuy ?
            entryPrice + PipsToPrice(GetConfigBreakEvenBufferPips()) :
            entryPrice - PipsToPrice(GetConfigBreakEvenBufferPips());

        // Only modify if new SL is better
        bool shouldModify = isBuy ? (newSL > currentSL) : (newSL < currentSL || currentSL == 0);

        if(shouldModify) {
            if(trade.PositionModify(secondTradeTicket, newSL, position.TakeProfit())) {
                breakEvenApplied = true;
                Print("Break-even applied at ", newSL);
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Apply trailing stop                                              |
//+------------------------------------------------------------------+
void ApplyTrailingStop() {
    if(!secondTradeOpen || secondTradeTicket == 0) return;

    if(!position.SelectByTicket(secondTradeTicket)) return;

    double entryPrice = position.PriceOpen();
    double currentPrice = position.PriceCurrent();
    double currentSL = position.StopLoss();

    bool isBuy = (position.PositionType() == POSITION_TYPE_BUY);
    double profitPips = isBuy ?
        PriceToPips(currentPrice - entryPrice) :
        PriceToPips(entryPrice - currentPrice);

    if(profitPips >= GetConfigTrailingStartPips()) {
        double trailDistance = PipsToPrice(GetConfigTrailingStepPips());
        double newSL;

        if(isBuy) {
            newSL = currentPrice - trailDistance;
            if(newSL > currentSL) {
                if(trade.PositionModify(secondTradeTicket, newSL, position.TakeProfit())) {
                    Print("Trailing stop updated to ", newSL);
                }
            }
        } else {
            newSL = currentPrice + trailDistance;
            if(newSL < currentSL || currentSL == 0) {
                if(trade.PositionModify(secondTradeTicket, newSL, position.TakeProfit())) {
                    Print("Trailing stop updated to ", newSL);
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Update trade statistics after close                              |
//+------------------------------------------------------------------+
void UpdateTradeStats() {
    lastTradeCloseTime = TimeCurrent();

    // Check history for last closed trade profit
    if(HistorySelect(TimeCurrent() - 60, TimeCurrent())) {
        int total = HistoryDealsTotal();
        if(total > 0) {
            ulong ticket = HistoryDealGetTicket(total - 1);
            if(ticket > 0) {
                double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
                double commission = HistoryDealGetDouble(ticket, DEAL_COMMISSION);
                double swap = HistoryDealGetDouble(ticket, DEAL_SWAP);
                lastClosedTradeProfit = profit + commission + swap;

                if(lastClosedTradeProfit < 0) {
                    consecutiveLosses++;
                    Print("Trade closed with loss. Consecutive losses: ", consecutiveLosses);
                } else {
                    consecutiveLosses = 0;
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Calculate lot size based on risk                                |
//+------------------------------------------------------------------+
double CalculateLotSize(double stopDistancePips = 0) {
    double balance = account.Balance();
    double riskAmount = balance * (GetConfigRiskPercent() / 100.0);

    // Use provided stop distance or calculate default
    if(stopDistancePips <= 0) {
        stopDistancePips = GetConfigWickClearance() + 10;
    }

    // Validate stop distance
    if(stopDistancePips > GetConfigMaxStopLossPips()) {
        Print("WARNING: Stop distance (", stopDistancePips, ") exceeds max (", GetConfigMaxStopLossPips(), ")");
        stopDistancePips = GetConfigMaxStopLossPips();
    }

    // Calculate lot size using pip value
    double pipValuePerLot = GetPipValuePerLot();
    if(pipValuePerLot <= 0) {
        Print("ERROR: Invalid pip value per lot");
        return 0;
    }

    double lotSize = riskAmount / (stopDistancePips * pipValuePerLot);

    // Apply constraints
    double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

    lotSize = MathMax(minLot, lotSize);
    lotSize = MathMin(maxLot, lotSize);
    lotSize = MathRound(lotSize / lotStep) * lotStep;

    // Validate margin
    double margin;
    if(!OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, lotSize,
                        SymbolInfoDouble(_Symbol, SYMBOL_ASK), margin)) {
        Print("ERROR: Cannot calculate margin");
        return minLot;
    }

    if(margin > account.FreeMargin() * 0.8) {
        Print("WARNING: Insufficient margin, reducing lot size");
        lotSize = minLot;
    }

    return NormalizeDouble(lotSize, 2);
}

//+------------------------------------------------------------------+
//| Close trades by comment                                         |
//+------------------------------------------------------------------+
void CloseTradesByComment(string comment) {
    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        if(position.SelectByIndex(i)) {
            if(position.Symbol() == _Symbol &&
               position.Magic() == MagicNumber &&
               position.Comment() == comment) {
                trade.PositionClose(position.Ticket());
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Reset trading state                                             |
//+------------------------------------------------------------------+
void ResetTradingState() {
    currentEngulfing.isValid = false;
    firstTradeOpen = false;
    secondTradeOpen = false;
    lastSignalBar = -1;
    firstTradeTicket = 0;
    secondTradeTicket = 0;
    firstTradeEntryPrice = 0;
    secondTradeEntryPrice = 0;
    secondTradeBarCount = 0;
    breakEvenApplied = false;
}

//+------------------------------------------------------------------+
//| HTTP Request Helper                                             |
//+------------------------------------------------------------------+
bool SendHTTPRequest(string endpoint, string method, string &data, string &response) {
    string headers = "Content-Type: application/json\r\n";

    if(StringLen(jwtToken) > 0) {
        headers += "Authorization: Bearer " + jwtToken + "\r\n";
    }

    if(StringLen(sessionId) > 0) {
        headers += "X-Session-Id: " + sessionId + "\r\n";
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

    Print("HTTP Request failed! Endpoint: ", endpoint, " Status: ", res);
    return false;
}

//+------------------------------------------------------------------+
//| JSON Helper: Extract string value                                |
//+------------------------------------------------------------------+
string ExtractJsonString(string &json, string key, string defaultValue = "") {
    string searchKey = "\"" + key + "\":\"";
    int start = StringFind(json, searchKey);
    if(start < 0) return defaultValue;

    start += StringLen(searchKey);
    int end = StringFind(json, "\"", start);
    if(end < 0) return defaultValue;

    return StringSubstr(json, start, end - start);
}

//+------------------------------------------------------------------+
//| JSON Helper: Extract integer value                               |
//+------------------------------------------------------------------+
int ExtractJsonInt(string &json, string key, int defaultValue = 0) {
    string searchKey = "\"" + key + "\":";
    int start = StringFind(json, searchKey);
    if(start < 0) return defaultValue;

    start += StringLen(searchKey);

    // Skip whitespace
    while(start < StringLen(json) && (StringGetCharacter(json, start) == ' ' || StringGetCharacter(json, start) == '\t'))
        start++;

    // Find end of number
    int end = start;
    while(end < StringLen(json)) {
        int c = StringGetCharacter(json, end);
        if((c >= '0' && c <= '9') || c == '-') end++;
        else break;
    }

    if(end == start) return defaultValue;
    return (int)StringToInteger(StringSubstr(json, start, end - start));
}

//+------------------------------------------------------------------+
//| JSON Helper: Extract double value                                |
//+------------------------------------------------------------------+
double ExtractJsonDouble(string &json, string key, double defaultValue = 0.0) {
    string searchKey = "\"" + key + "\":";
    int start = StringFind(json, searchKey);
    if(start < 0) return defaultValue;

    start += StringLen(searchKey);

    // Skip whitespace
    while(start < StringLen(json) && (StringGetCharacter(json, start) == ' ' || StringGetCharacter(json, start) == '\t'))
        start++;

    // Find end of number
    int end = start;
    while(end < StringLen(json)) {
        int c = StringGetCharacter(json, end);
        if((c >= '0' && c <= '9') || c == '-' || c == '.') end++;
        else break;
    }

    if(end == start) return defaultValue;
    return StringToDouble(StringSubstr(json, start, end - start));
}

//+------------------------------------------------------------------+
//| JSON Helper: Extract boolean value                               |
//+------------------------------------------------------------------+
bool ExtractJsonBool(string &json, string key, bool defaultValue = false) {
    string searchKey = "\"" + key + "\":";
    int start = StringFind(json, searchKey);
    if(start < 0) return defaultValue;

    start += StringLen(searchKey);

    // Skip whitespace
    while(start < StringLen(json) && (StringGetCharacter(json, start) == ' ' || StringGetCharacter(json, start) == '\t'))
        start++;

    // Check for true/false
    if(StringFind(json, "true", start) == start) return true;
    if(StringFind(json, "false", start) == start) return false;

    return defaultValue;
}

//+------------------------------------------------------------------+
//| Load default config from input parameters (fallback)             |
//+------------------------------------------------------------------+
void LoadDefaultConfig() {
    // Trading
    serverConfig.riskPercent = RiskPercent;
    serverConfig.maxRiskPercent = MaxRiskPercent;
    serverConfig.wickClearance = WickClearance;
    serverConfig.enableSecondTrade = EnableSecondTrade;
    serverConfig.slippage = Slippage;
    serverConfig.maxStopLossPips = MaxStopLossPips;

    // Exit Strategy
    serverConfig.useTrailingStop = UseTrailingStop;
    serverConfig.trailingStartPips = TrailingStartPips;
    serverConfig.trailingStepPips = TrailingStepPips;
    serverConfig.useBreakEven = UseBreakEven;
    serverConfig.breakEvenPips = BreakEvenPips;
    serverConfig.breakEvenBufferPips = BreakEvenBufferPips;
    serverConfig.closeOnReversal = CloseOnReversal;

    // Guard Rails
    serverConfig.maxSpread = MaxSpread;
    serverConfig.maxTradesPerDay = MaxTradesPerDay;
    serverConfig.restMinutesBetweenTrades = RestMinutesBetweenTrades;
    serverConfig.restMinutesAfterLoss = RestMinutesAfterLoss;
    serverConfig.maxConsecutiveLosses = MaxConsecutiveLosses;
    serverConfig.extendedBreakMinutes = ExtendedBreakMinutes;
    serverConfig.maxDailyDrawdownPercent = MaxDailyDrawdownPercent;

    // Market Filters
    serverConfig.avoidMondayOpen = AvoidMondayOpen;
    serverConfig.avoidFridayClose = AvoidFridayClose;

    // Meta
    serverConfig.configVersion = 0; // Local fallback
    serverConfig.isLoaded = false;

    Print("Loaded fallback config from input parameters");
}

//+------------------------------------------------------------------+
//| Parse server config response                                     |
//+------------------------------------------------------------------+
bool ParseServerConfig(string &response) {
    // Check for success
    if(StringFind(response, "\"success\":true") < 0) {
        Print("Server config response indicates failure");
        return false;
    }

    // Extract config version
    int newVersion = ExtractJsonInt(response, "configVersion", 0);

    // Skip if same version (no changes)
    if(serverConfig.isLoaded && newVersion == serverConfig.configVersion) {
        return true; // No update needed
    }

    // Trading settings
    serverConfig.riskPercent = ExtractJsonDouble(response, "riskPercent", RiskPercent);
    serverConfig.maxRiskPercent = ExtractJsonDouble(response, "maxRiskPercent", MaxRiskPercent);
    serverConfig.wickClearance = ExtractJsonInt(response, "wickClearance", WickClearance);
    serverConfig.enableSecondTrade = ExtractJsonBool(response, "enableSecondTrade", EnableSecondTrade);
    serverConfig.slippage = ExtractJsonInt(response, "slippage", Slippage);
    serverConfig.maxStopLossPips = ExtractJsonInt(response, "maxStopLossPips", MaxStopLossPips);

    // Exit Strategy
    serverConfig.useTrailingStop = ExtractJsonBool(response, "useTrailingStop", UseTrailingStop);
    serverConfig.trailingStartPips = ExtractJsonInt(response, "trailingStartPips", TrailingStartPips);
    serverConfig.trailingStepPips = ExtractJsonInt(response, "trailingStepPips", TrailingStepPips);
    serverConfig.useBreakEven = ExtractJsonBool(response, "useBreakEven", UseBreakEven);
    serverConfig.breakEvenPips = ExtractJsonInt(response, "breakEvenPips", BreakEvenPips);
    serverConfig.breakEvenBufferPips = ExtractJsonInt(response, "breakEvenBufferPips", BreakEvenBufferPips);
    serverConfig.closeOnReversal = ExtractJsonBool(response, "closeOnReversal", CloseOnReversal);

    // Guard Rails
    serverConfig.maxSpread = ExtractJsonInt(response, "maxSpread", MaxSpread);
    serverConfig.maxTradesPerDay = ExtractJsonInt(response, "maxTradesPerDay", MaxTradesPerDay);
    serverConfig.restMinutesBetweenTrades = ExtractJsonInt(response, "restMinutesBetweenTrades", RestMinutesBetweenTrades);
    serverConfig.restMinutesAfterLoss = ExtractJsonInt(response, "restMinutesAfterLoss", RestMinutesAfterLoss);
    serverConfig.maxConsecutiveLosses = ExtractJsonInt(response, "maxConsecutiveLosses", MaxConsecutiveLosses);
    serverConfig.extendedBreakMinutes = ExtractJsonInt(response, "extendedBreakMinutes", ExtendedBreakMinutes);
    serverConfig.maxDailyDrawdownPercent = ExtractJsonDouble(response, "maxDailyDrawdownPercent", MaxDailyDrawdownPercent);

    // Market Filters
    serverConfig.avoidMondayOpen = ExtractJsonBool(response, "avoidMondayOpen", AvoidMondayOpen);
    serverConfig.avoidFridayClose = ExtractJsonBool(response, "avoidFridayClose", AvoidFridayClose);

    // Meta
    serverConfig.configVersion = newVersion;
    serverConfig.isLoaded = true;

    return true;
}

//+------------------------------------------------------------------+
//| Fetch configuration from server                                  |
//+------------------------------------------------------------------+
bool FetchServerConfig() {
    string emptyData = "";
    string response;

    if(!SendHTTPRequest("/mt5/config", "GET", emptyData, response)) {
        Print("Failed to fetch server config - using fallback");
        return false;
    }

    if(!ParseServerConfig(response)) {
        Print("Failed to parse server config - using fallback");
        return false;
    }

    Print("Server config loaded successfully. Version: ", serverConfig.configVersion);
    Print("Config: Risk=", serverConfig.riskPercent, "%, MaxSpread=", serverConfig.maxSpread,
          ", MaxTrades/Day=", serverConfig.maxTradesPerDay, ", Drawdown=", serverConfig.maxDailyDrawdownPercent, "%");

    lastConfigFetch = TimeCurrent();
    return true;
}

//+------------------------------------------------------------------+
//| Get effective config value (server if loaded, else fallback)     |
//+------------------------------------------------------------------+
double GetConfigRiskPercent() { return serverConfig.isLoaded ? serverConfig.riskPercent : RiskPercent; }
double GetConfigMaxRiskPercent() { return serverConfig.isLoaded ? serverConfig.maxRiskPercent : MaxRiskPercent; }
int GetConfigWickClearance() { return serverConfig.isLoaded ? serverConfig.wickClearance : WickClearance; }
bool GetConfigEnableSecondTrade() { return serverConfig.isLoaded ? serverConfig.enableSecondTrade : EnableSecondTrade; }
int GetConfigSlippage() { return serverConfig.isLoaded ? serverConfig.slippage : Slippage; }
int GetConfigMaxStopLossPips() { return serverConfig.isLoaded ? serverConfig.maxStopLossPips : MaxStopLossPips; }
bool GetConfigUseTrailingStop() { return serverConfig.isLoaded ? serverConfig.useTrailingStop : UseTrailingStop; }
int GetConfigTrailingStartPips() { return serverConfig.isLoaded ? serverConfig.trailingStartPips : TrailingStartPips; }
int GetConfigTrailingStepPips() { return serverConfig.isLoaded ? serverConfig.trailingStepPips : TrailingStepPips; }
bool GetConfigUseBreakEven() { return serverConfig.isLoaded ? serverConfig.useBreakEven : UseBreakEven; }
int GetConfigBreakEvenPips() { return serverConfig.isLoaded ? serverConfig.breakEvenPips : BreakEvenPips; }
int GetConfigBreakEvenBufferPips() { return serverConfig.isLoaded ? serverConfig.breakEvenBufferPips : BreakEvenBufferPips; }
bool GetConfigCloseOnReversal() { return serverConfig.isLoaded ? serverConfig.closeOnReversal : CloseOnReversal; }
int GetConfigMaxSpread() { return serverConfig.isLoaded ? serverConfig.maxSpread : MaxSpread; }
int GetConfigMaxTradesPerDay() { return serverConfig.isLoaded ? serverConfig.maxTradesPerDay : MaxTradesPerDay; }
int GetConfigRestMinutesBetweenTrades() { return serverConfig.isLoaded ? serverConfig.restMinutesBetweenTrades : RestMinutesBetweenTrades; }
int GetConfigRestMinutesAfterLoss() { return serverConfig.isLoaded ? serverConfig.restMinutesAfterLoss : RestMinutesAfterLoss; }
int GetConfigMaxConsecutiveLosses() { return serverConfig.isLoaded ? serverConfig.maxConsecutiveLosses : MaxConsecutiveLosses; }
int GetConfigExtendedBreakMinutes() { return serverConfig.isLoaded ? serverConfig.extendedBreakMinutes : ExtendedBreakMinutes; }
double GetConfigMaxDailyDrawdownPercent() { return serverConfig.isLoaded ? serverConfig.maxDailyDrawdownPercent : MaxDailyDrawdownPercent; }
bool GetConfigAvoidMondayOpen() { return serverConfig.isLoaded ? serverConfig.avoidMondayOpen : AvoidMondayOpen; }
bool GetConfigAvoidFridayClose() { return serverConfig.isLoaded ? serverConfig.avoidFridayClose : AvoidFridayClose; }

//+------------------------------------------------------------------+
//| Authenticate bot with server                                    |
//+------------------------------------------------------------------+
bool AuthenticateBot() {
    Print("=== Starting Authentication ===");

    string data = "{";
    data += "\"magicNumber\":" + IntegerToString(MagicNumber) + ",";
    data += "\"accountNumber\":\"" + IntegerToString(account.Login()) + "\",";
    data += "\"broker\":\"" + account.Company() + "\",";
    data += "\"symbol\":\"" + _Symbol + "\",";
    data += "\"version\":\"2.0.0\"";
    data += "}";

    string response;
    if(SendHTTPRequest("/mt5/auth", "POST", data, response)) {
        // Parse session ID
        int start = StringFind(response, "\"sessionId\":\"");
        if(start >= 0) {
            start += 13;
            int end = StringFind(response, "\"", start);
            sessionId = StringSubstr(response, start, end - start);
        } else {
            Print("ERROR: sessionId not found");
            return false;
        }

        // Parse JWT token
        start = StringFind(response, "\"jwtToken\":\"");
        if(start >= 0) {
            start += 12;
            int end = StringFind(response, "\"", start);
            jwtToken = StringSubstr(response, start, end - start);
            Print("Authenticated successfully!");
            return true;
        } else {
            Print("ERROR: jwtToken not found");
            return false;
        }
    }

    Print("ERROR: Authentication request failed");
    return false;
}

//+------------------------------------------------------------------+
//| Send heartbeat to server                                        |
//+------------------------------------------------------------------+
void SendHeartbeat() {
    string data = "{";
    data += "\"balance\":" + DoubleToString(account.Balance(), 2) + ",";
    data += "\"equity\":" + DoubleToString(account.Equity(), 2) + ",";
    data += "\"margin\":" + DoubleToString(account.Margin(), 2) + ",";
    data += "\"freeMargin\":" + DoubleToString(account.FreeMargin(), 2) + ",";
    data += "\"marginLevel\":" + DoubleToString(account.MarginLevel(), 2) + ",";
    data += "\"openPositions\":" + IntegerToString(PositionsTotal()) + ",";
    data += "\"botEnabled\":" + (botEnabled ? "true" : "false") + ",";
    data += "\"dailyTrades\":" + IntegerToString(dailyTradesCount) + ",";
    data += "\"consecutiveLosses\":" + IntegerToString(consecutiveLosses);
    data += "}";

    string response;
    if(SendHTTPRequest("/mt5/heartbeat", "POST", data, response)) {
        if(StringFind(response, "\"command\":\"stop\"") >= 0) {
            botEnabled = false;
            Print("Bot stopped by server command");
        } else if(StringFind(response, "\"command\":\"start\"") >= 0) {
            botEnabled = true;
            Print("Bot started by server command");
        }
    }
}

//+------------------------------------------------------------------+
//| Send position update to server                                  |
//+------------------------------------------------------------------+
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
                positions += "\"takeProfit\":" + DoubleToString(position.TakeProfit(), g_digits) + ",";
                positions += "\"profit\":" + DoubleToString(position.Profit(), 2) + ",";
                positions += "\"openTime\":\"" + TimeToString(position.Time()) + "\"";
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

//+------------------------------------------------------------------+
//| Send signal notification to server                              |
//+------------------------------------------------------------------+
void SendSignalNotification(EngulfingBar &bar) {
    string data = "{";
    data += "\"signalType\":\"" + (bar.isBullish ? "BUY" : "SELL") + "\",";
    data += "\"symbol\":\"" + _Symbol + "\",";
    data += "\"pattern\":\"engulfing\",";
    data += "\"open\":" + DoubleToString(bar.open, g_digits) + ",";
    data += "\"high\":" + DoubleToString(bar.high, g_digits) + ",";
    data += "\"low\":" + DoubleToString(bar.low, g_digits) + ",";
    data += "\"close\":" + DoubleToString(bar.close, g_digits) + ",";
    data += "\"time\":\"" + TimeToString(bar.time) + "\"";
    data += "}";

    string response;
    SendHTTPRequest("/mt5/signals", "POST", data, response);
}

//+------------------------------------------------------------------+
//| Send trade notification to server                               |
//+------------------------------------------------------------------+
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

//+------------------------------------------------------------------+
//| Send disconnection notice to server                             |
//+------------------------------------------------------------------+
void SendDisconnectionNotice(int reason) {
    string data = "{";
    data += "\"reason\":" + IntegerToString(reason) + ",";
    data += "\"message\":\"" + GetDisconnectReason(reason) + "\"";
    data += "}";

    string response;
    SendHTTPRequest("/mt5/disconnect", "POST", data, response);
}

//+------------------------------------------------------------------+
//| Get disconnect reason string                                    |
//+------------------------------------------------------------------+
string GetDisconnectReason(int reason) {
    switch(reason) {
        case REASON_PROGRAM: return "Expert removed from chart";
        case REASON_REMOVE: return "Program removed from chart";
        case REASON_RECOMPILE: return "Program recompiled";
        case REASON_CHARTCHANGE: return "Symbol or timeframe changed";
        case REASON_CHARTCLOSE: return "Chart closed";
        case REASON_PARAMETERS: return "Input parameters changed";
        case REASON_ACCOUNT: return "Account changed";
        case REASON_TEMPLATE: return "Template applied";
        case REASON_INITFAILED: return "Initialization failed";
        case REASON_CLOSE: return "Terminal closed";
        default: return "Unknown reason";
    }
}
//+------------------------------------------------------------------+
