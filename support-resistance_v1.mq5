//+------------------------------------------------------------------+
//|                                          SRZoneTrend_EA_v1.mq5   |
//|                   Support/Resistance Zone + MTF EMA Strategy     |
//|                                                       Version 1.0 |
//|  Multi-Timeframe: H4 200 EMA Bias + M15 10/23 EMA Crossover      |
//+------------------------------------------------------------------+
#property copyright "FXBot Trading"
#property link      "https://fxbot.trading"
#property version   "1.00"
#property strict
#property description "Support/Resistance Zone Trading with Multi-Timeframe EMA Analysis"
#property description "H4: 200 EMA for directional bias | M15: 10/23 EMA crossover for entries"
#property description "Features: Breakout & Retest detection, Session Filter, Flexible Risk"
#property description "Universal: Works on any symbol with correct pip value calculation"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\AccountInfo.mqh>

//+------------------------------------------------------------------+
//| Input Parameters                                                 |
//+------------------------------------------------------------------+
input group "=== Multi-Timeframe EMA Settings ==="
input ENUM_TIMEFRAMES HTF_Timeframe = PERIOD_H4;         // Higher Timeframe for Bias
input int      HTF_EMA_Period       = 200;               // HTF EMA Period (Trend Filter)
input ENUM_TIMEFRAMES LTF_Timeframe = PERIOD_M15;        // Lower Timeframe for Entry
input int      LTF_EMA_Fast         = 10;                // LTF Fast EMA Period
input int      LTF_EMA_Slow         = 23;                // LTF Slow EMA Period
input ENUM_APPLIED_PRICE EMA_Price  = PRICE_CLOSE;       // Price for EMA calculation

input group "=== Trend Strength Filter ==="
input bool     UseADXFilter         = true;              // Use ADX to filter weak trends
input int      ADX_Period           = 14;                // ADX Period
input double   ADX_Threshold        = 25.0;              // Minimum ADX for trending market
input double   OverextensionATR     = 2.5;               // Max ATR distance from 200 EMA

input group "=== Support/Resistance Zone Detection ==="
input int      ZoneLookbackBars     = 200;               // Bars to look back for S/R zones
input int      SwingStrength        = 5;                 // Swing detection strength (bars each side)
input double   ZoneWidthATR         = 0.5;               // Zone width as ATR multiplier
input int      MinTouchCount        = 2;                 // Minimum touches for valid zone
input int      MaxActiveZones       = 10;                // Maximum zones to track
input double   ZoneMergeATR         = 0.3;               // Merge zones closer than this ATR
input int      ZoneExpiryBars       = 500;               // Zone expires after N bars without touch

input group "=== Entry Mode ==="
input bool     EnableBreakoutEntry  = true;              // Enable breakout entries
input bool     EnableRetestEntry    = true;              // Enable retest entries
input double   BreakoutATR          = 1.0;               // Min ATR penetration for breakout
input int      RetestMinBars        = 2;                 // Min bars after breakout for retest
input int      RetestMaxBars        = 20;                // Max bars to wait for retest
input double   RetestZoneATR        = 0.5;               // Retest zone width in ATR

input group "=== Momentum Confirmation ==="
input bool     UseRSIFilter         = true;              // Use RSI for momentum confirmation
input int      RSI_Period           = 14;                // RSI Period
input double   RSI_OverboughtLevel  = 70.0;              // RSI Overbought level
input double   RSI_OversoldLevel    = 30.0;              // RSI Oversold level

input group "=== Stop Loss Settings ==="
input double   SL_ATR_Multiplier    = 1.5;               // SL = ATR x Multiplier
input int      SL_ZoneBuffer_Pips   = 5;                 // Extra buffer beyond zone (pips)
input int      SL_SpreadBuffer_Pips = 3;                 // Extra buffer for spread (pips)

input group "=== Take Profit Settings ==="
input bool     TP_UseNextZone       = true;              // Use next S/R zone as TP
input double   TP_RiskRewardRatio   = 2.0;               // Risk:Reward if no zone found
input double   TP_ZoneBuffer_Pips   = 5.0;               // Buffer before zone for TP

input group "=== Breakeven Settings ==="
input bool     EnableBreakeven      = true;              // Move SL to entry at 1:1
input double   BreakevenBuffer_Pips = 1.0;               // Buffer above/below entry (pips)

input group "=== Trailing Stop ==="
input bool     EnableTrailing       = true;              // Enable trailing stop
input bool     TrailUseEMA          = true;              // Trail using slow EMA
input double   TrailATR_Multiplier  = 0.3;               // Trail buffer as ATR multiplier

input group "=== Risk Management ==="
input bool     UseFixedRisk         = false;             // Use fixed $ risk instead of %
input double   RiskPercent          = 1.0;               // Risk per trade (% of balance)
input double   FixedRiskAmount      = 50.0;              // Fixed risk amount in $
input int      MagicNumber          = 246810;            // Magic Number (unique for this EA)
input int      Slippage             = 30;                // Maximum slippage (points)

input group "=== Daily Limits ==="
input bool     EnableDailyLimits    = true;              // Enable daily P&L limits
input double   MaxDailyLossAmount   = 100.0;             // Max daily loss in $
input double   MaxDailyLossPercent  = 5.0;               // Max daily loss in % of balance
input double   DailyProfitTarget    = 200.0;             // Daily profit target in $
input double   DailyProfitPercent   = 10.0;              // Daily profit target in %
input bool     StopOnProfitTarget   = false;             // Stop trading when profit target reached
input int      MaxTradesPerDay      = 5;                 // Max trades per day (0 = unlimited)

input group "=== Trading Sessions ==="
input bool     EnableSessionFilter  = true;              // Enable session-based trading
input int      BrokerGMTOffset      = 2;                 // Broker server GMT offset

input group "=== Asian Session ==="
input bool     TradeAsianSession    = true;              // Trade during Asian session
input int      AsianStartHour       = 0;                 // Asian start (GMT)
input int      AsianEndHour         = 9;                 // Asian end (GMT)

input group "=== London Session ==="
input bool     TradeLondonSession   = true;              // Trade during London session
input int      LondonStartHour      = 7;                 // London start (GMT)
input int      LondonEndHour        = 16;                // London end (GMT)

input group "=== New York Session ==="
input bool     TradeNewYorkSession  = true;              // Trade during New York session
input int      NewYorkStartHour     = 13;                // New York start (GMT)
input int      NewYorkEndHour       = 22;                // New York end (GMT)

input group "=== Spread Filter ==="
input double   MaxSpreadPips        = 5.0;               // Max spread allowed (pips)

input group "=== Debug ==="
input bool     EnableLogs           = true;              // Enable debug logging
input bool     DrawZonesOnChart     = true;              // Draw S/R zones on chart

//+------------------------------------------------------------------+
//| Enums and Structures                                             |
//+------------------------------------------------------------------+
enum ENUM_ZONE_TYPE {
   ZONE_SUPPORT,
   ZONE_RESISTANCE,
   ZONE_FLIP_SUPPORT,      // Former resistance now support
   ZONE_FLIP_RESISTANCE    // Former support now resistance
};

enum ENUM_ENTRY_TYPE {
   ENTRY_NONE,
   ENTRY_BREAKOUT,
   ENTRY_RETEST
};

enum ENUM_CROSS_TYPE {
   CROSS_NONE,
   CROSS_BULLISH,
   CROSS_BEARISH
};

enum SESSION_TYPE {
   SESSION_NONE = 0,
   SESSION_ASIAN = 1,
   SESSION_LONDON = 2,
   SESSION_NEWYORK = 3,
   SESSION_OVERLAP_TOKYO_LONDON = 4,
   SESSION_OVERLAP_LONDON_NY = 5
};

struct SRZone {
   int            id;
   ENUM_ZONE_TYPE type;
   double         price_upper;
   double         price_lower;
   datetime       time_created;
   datetime       time_last_touch;
   int            touch_count;
   double         strength;          // 0-100 score
   bool           is_broken;
   bool           is_active;
   datetime       break_time;        // When zone was broken (for retest)
   
   double MidPrice() { return (price_upper + price_lower) / 2.0; }
   bool   ContainsPrice(double price) { return (price >= price_lower && price <= price_upper); }
};

struct FlipZone {
   double         level;
   bool           was_resistance;
   datetime       break_time;
   int            retest_count;
   bool           is_active;
};

//+------------------------------------------------------------------+
//| Global Variables                                                 |
//+------------------------------------------------------------------+
CTrade trade;
CPositionInfo position;
CAccountInfo account;

// Symbol metrics
double g_pipSize = 0.0;
double g_pipValue = 0.0;
double g_point = 0.0;
int    g_digits = 0;
double g_minLot = 0.01;
double g_maxLot = 100.0;
double g_lotStep = 0.01;

// Indicator handles
int    h_htf_ema = INVALID_HANDLE;       // HTF 200 EMA
int    h_ltf_ema_fast = INVALID_HANDLE;  // LTF Fast EMA
int    h_ltf_ema_slow = INVALID_HANDLE;  // LTF Slow EMA
int    h_htf_atr = INVALID_HANDLE;       // HTF ATR
int    h_ltf_atr = INVALID_HANDLE;       // LTF ATR
int    h_adx = INVALID_HANDLE;           // ADX indicator
int    h_rsi = INVALID_HANDLE;           // RSI indicator

// S/R Zone tracking
SRZone   g_zones[];
int      g_zone_count = 0;
int      g_next_zone_id = 1;

// Flip zone tracking (for retest entries)
FlipZone g_flip_zones[];
int      g_flip_zone_count = 0;

// State tracking
datetime g_lastBarTime = 0;
int      g_dailyTrades = 0;
datetime g_dailyResetTime = 0;
bool     g_botEnabled = true;

// Daily P&L tracking
double   g_dailyStartBalance = 0;
double   g_dailyPnL = 0;
double   g_dailyMaxLoss = 0;
double   g_dailyProfitGoal = 0;
bool     g_dailyLossLimitHit = false;
bool     g_dailyProfitTargetHit = false;

// Session tracking
SESSION_TYPE g_currentSession = SESSION_NONE;

// Last signal state (to prevent duplicate entries)
datetime g_lastSignalTime = 0;
int      g_lastSignalDirection = 0;

//+------------------------------------------------------------------+
//| Logging function                                                 |
//+------------------------------------------------------------------+
void Log(string msg, string cat = "INFO") {
   if(EnableLogs) Print("[", cat, "] ", msg);
}

//+------------------------------------------------------------------+
//| Universal Pip Size Calculation                                   |
//+------------------------------------------------------------------+
double GetPipSize() {
   // Universal calculation based on digits
   // 2-3 digits: metals, indices (pip = 0.01 or 0.1)
   // 4-5 digits: forex pairs (pip = 0.0001 or 0.00001 -> use 0.0001)
   
   if(g_digits == 5 || g_digits == 3) {
      return g_point * 10;  // 5-digit forex or 3-digit metals
   }
   return g_point;  // 4-digit forex or 2-digit
}

//+------------------------------------------------------------------+
//| Safe Tick Value Retrieval (handles zero returns)                 |
//+------------------------------------------------------------------+
double SafeGetTickValue() {
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   
   // Some brokers return 0 initially - use OrderCalcProfit as fallback
   if(tickValue == 0 || tickValue == EMPTY_VALUE) {
      double profit = 0;
      double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      
      if(tickSize > 0 && OrderCalcProfit(ORDER_TYPE_BUY, _Symbol, 1.0, bid, bid + tickSize, profit)) {
         tickValue = MathAbs(profit);
      }
   }
   
   return tickValue;
}

//+------------------------------------------------------------------+
//| Get Pip Value for Position Sizing                                |
//+------------------------------------------------------------------+
double GetPipValue(double lots = 1.0) {
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SafeGetTickValue();
   
   if(tickSize <= 0) return 0;
   return (tickValue / tickSize) * g_pipSize * lots;
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
//| Get GMT Hour from broker time                                    |
//+------------------------------------------------------------------+
int GetGMTHour() {
   datetime serverTime = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(serverTime, dt);
   int gmtHour = ((dt.hour - BrokerGMTOffset) % 24 + 24) % 24;
   return gmtHour;
}

//+------------------------------------------------------------------+
//| Determine current trading session                                |
//+------------------------------------------------------------------+
SESSION_TYPE GetCurrentSession() {
   int gmtHour = GetGMTHour();
   
   bool inAsian = (gmtHour >= AsianStartHour && gmtHour < AsianEndHour);
   bool inLondon = (gmtHour >= LondonStartHour && gmtHour < LondonEndHour);
   bool inNewYork = (gmtHour >= NewYorkStartHour && gmtHour < NewYorkEndHour);
   
   if(inLondon && inNewYork) return SESSION_OVERLAP_LONDON_NY;
   if(inAsian && inLondon) return SESSION_OVERLAP_TOKYO_LONDON;
   if(inAsian) return SESSION_ASIAN;
   if(inLondon) return SESSION_LONDON;
   if(inNewYork) return SESSION_NEWYORK;
   
   return SESSION_NONE;
}

//+------------------------------------------------------------------+
//| Get session name for logging                                     |
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
//| Check if trading allowed in current session                      |
//+------------------------------------------------------------------+
bool IsTradingAllowedInSession() {
   if(!EnableSessionFilter) return true;
   
   g_currentSession = GetCurrentSession();
   
   switch(g_currentSession) {
      case SESSION_ASIAN: return TradeAsianSession;
      case SESSION_LONDON: return TradeLondonSession;
      case SESSION_NEWYORK: return TradeNewYorkSession;
      case SESSION_OVERLAP_TOKYO_LONDON: return (TradeAsianSession || TradeLondonSession);
      case SESSION_OVERLAP_LONDON_NY: return (TradeLondonSession || TradeNewYorkSession);
      default: return false;
   }
}

//+------------------------------------------------------------------+
//| Calculate daily limits                                           |
//+------------------------------------------------------------------+
void CalculateDailyLimits() {
   if(!EnableDailyLimits) {
      g_dailyMaxLoss = 0;
      g_dailyProfitGoal = 0;
      return;
   }
   
   double lossFromAmount = MaxDailyLossAmount;
   double lossFromPercent = g_dailyStartBalance * (MaxDailyLossPercent / 100.0);
   
   if(MaxDailyLossAmount > 0 && MaxDailyLossPercent > 0)
      g_dailyMaxLoss = MathMax(lossFromAmount, lossFromPercent);
   else if(MaxDailyLossAmount > 0)
      g_dailyMaxLoss = lossFromAmount;
   else if(MaxDailyLossPercent > 0)
      g_dailyMaxLoss = lossFromPercent;
   else
      g_dailyMaxLoss = 0;
   
   double profitFromAmount = DailyProfitTarget;
   double profitFromPercent = g_dailyStartBalance * (DailyProfitPercent / 100.0);
   
   if(DailyProfitTarget > 0 && DailyProfitPercent > 0)
      g_dailyProfitGoal = MathMax(profitFromAmount, profitFromPercent);
   else if(DailyProfitTarget > 0)
      g_dailyProfitGoal = profitFromAmount;
   else if(DailyProfitPercent > 0)
      g_dailyProfitGoal = profitFromPercent;
   else
      g_dailyProfitGoal = 0;
}

//+------------------------------------------------------------------+
//| Update daily P&L                                                 |
//+------------------------------------------------------------------+
void UpdateDailyPnL() {
   g_dailyPnL = account.Balance() - g_dailyStartBalance;
}

//+------------------------------------------------------------------+
//| Check daily limits                                               |
//+------------------------------------------------------------------+
bool CheckDailyLimits() {
   if(!EnableDailyLimits) return true;
   
   UpdateDailyPnL();
   
   if(g_dailyMaxLoss > 0 && g_dailyPnL <= -g_dailyMaxLoss) {
      if(!g_dailyLossLimitHit) {
         g_dailyLossLimitHit = true;
         Log("!!! DAILY LOSS LIMIT REACHED: $" + DoubleToString(g_dailyPnL, 2), "LIMIT");
      }
      return false;
   }
   
   if(StopOnProfitTarget && g_dailyProfitGoal > 0 && g_dailyPnL >= g_dailyProfitGoal) {
      if(!g_dailyProfitTargetHit) {
         g_dailyProfitTargetHit = true;
         Log("*** DAILY PROFIT TARGET REACHED: $" + DoubleToString(g_dailyPnL, 2), "TARGET");
      }
      return false;
   }
   
   return true;
}

//+------------------------------------------------------------------+
//| Check for daily reset                                            |
//+------------------------------------------------------------------+
void CheckDailyReset() {
   MqlDateTime dt, resetDt;
   TimeToStruct(TimeCurrent(), dt);
   TimeToStruct(g_dailyResetTime, resetDt);
   
   if(resetDt.day_of_year != dt.day_of_year) {
      g_dailyTrades = 0;
      g_dailyResetTime = TimeCurrent();
      g_dailyStartBalance = account.Balance();
      g_dailyPnL = 0;
      g_dailyLossLimitHit = false;
      g_dailyProfitTargetHit = false;
      CalculateDailyLimits();
      
      Log("=== DAILY RESET === Balance: $" + DoubleToString(g_dailyStartBalance, 2), "RESET");
   }
}

//+------------------------------------------------------------------+
//| Detect Swing High                                                |
//+------------------------------------------------------------------+
bool IsSwingHigh(int index, int window, const double &high[]) {
   for(int i = 1; i <= window; i++) {
      if(index - i < 0 || index + i >= ArraySize(high)) return false;
      if(high[index] <= high[index - i] || high[index] <= high[index + i])
         return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Detect Swing Low                                                 |
//+------------------------------------------------------------------+
bool IsSwingLow(int index, int window, const double &low[]) {
   for(int i = 1; i <= window; i++) {
      if(index - i < 0 || index + i >= ArraySize(low)) return false;
      if(low[index] >= low[index - i] || low[index] >= low[index + i])
         return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Get ATR value from handle                                        |
//+------------------------------------------------------------------+
double GetATR(int handle, int shift = 1) {
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(handle, 0, shift, 1, atr) <= 0) return 0;
   return atr[0];
}

//+------------------------------------------------------------------+
//| Calculate Zone Strength Score (0-100)                            |
//+------------------------------------------------------------------+
double CalculateZoneStrength(int touchCount, double avgReaction, int age, double volume) {
   double score = 0;
   
   // Touch count (30% weight) - 3 touches = 50%, 5+ = 100%
   if(touchCount >= 5) score += 30;
   else if(touchCount >= 3) score += 15;
   else score += touchCount * 5;
   
   // Reaction magnitude (25% weight)
   double atr = GetATR(h_htf_atr);
   if(atr > 0) {
      double reactionRatio = avgReaction / atr;
      if(reactionRatio >= 1.5) score += 25;
      else if(reactionRatio >= 1.0) score += 15;
      else score += reactionRatio * 10;
   }
   
   // Recency (25% weight) - newer zones score higher
   if(age <= 50) score += 25;
   else if(age <= 100) score += 20;
   else if(age <= 200) score += 15;
   else if(age <= 300) score += 10;
   else score += 5;
   
   // Volume factor (20% weight) - simplified
   score += 10;  // Base score since volume analysis is complex
   
   return MathMin(score, 100);
}

//+------------------------------------------------------------------+
//| Detect and Update S/R Zones                                      |
//+------------------------------------------------------------------+
void DetectSRZones() {
   double high[], low[], close[];
   datetime time[];
   
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   ArraySetAsSeries(close, true);
   ArraySetAsSeries(time, true);
   
   int bars = MathMin(ZoneLookbackBars, iBars(_Symbol, HTF_Timeframe) - SwingStrength - 1);
   
   if(CopyHigh(_Symbol, HTF_Timeframe, 0, bars, high) <= 0) return;
   if(CopyLow(_Symbol, HTF_Timeframe, 0, bars, low) <= 0) return;
   if(CopyClose(_Symbol, HTF_Timeframe, 0, bars, close) <= 0) return;
   if(CopyTime(_Symbol, HTF_Timeframe, 0, bars, time) <= 0) return;
   
   double atr = GetATR(h_htf_atr);
   if(atr <= 0) return;
   
   double zoneWidth = atr * ZoneWidthATR;
   double mergeThreshold = atr * ZoneMergeATR;
   
   // Temporary arrays for new swing points
   double swingHighs[];
   double swingLows[];
   datetime swingHighTimes[];
   datetime swingLowTimes[];
   
   ArrayResize(swingHighs, 0);
   ArrayResize(swingLows, 0);
   ArrayResize(swingHighTimes, 0);
   ArrayResize(swingLowTimes, 0);
   
   // Detect swing points
   for(int i = SwingStrength; i < bars - SwingStrength; i++) {
      if(IsSwingHigh(i, SwingStrength, high)) {
         int size = ArraySize(swingHighs);
         ArrayResize(swingHighs, size + 1);
         ArrayResize(swingHighTimes, size + 1);
         swingHighs[size] = high[i];
         swingHighTimes[size] = time[i];
      }
      
      if(IsSwingLow(i, SwingStrength, low)) {
         int size = ArraySize(swingLows);
         ArrayResize(swingLows, size + 1);
         ArrayResize(swingLowTimes, size + 1);
         swingLows[size] = low[i];
         swingLowTimes[size] = time[i];
      }
   }
   
   // Clear old zones and rebuild
   ArrayResize(g_zones, 0);
   g_zone_count = 0;
   
   // Create resistance zones from swing highs
   for(int i = 0; i < ArraySize(swingHighs); i++) {
      double level = swingHighs[i];
      int touches = 1;
      
      // Count how many swing highs are near this level
      for(int j = i + 1; j < ArraySize(swingHighs); j++) {
         if(MathAbs(swingHighs[j] - level) <= mergeThreshold) {
            level = (level * touches + swingHighs[j]) / (touches + 1);  // Average
            touches++;
         }
      }
      
      // Check if zone already exists (avoid duplicates)
      bool exists = false;
      for(int z = 0; z < g_zone_count; z++) {
         if(MathAbs(g_zones[z].MidPrice() - level) <= mergeThreshold) {
            exists = true;
            if(touches > g_zones[z].touch_count) {
               g_zones[z].touch_count = touches;
               g_zones[z].strength = CalculateZoneStrength(touches, atr, i, 0);
            }
            break;
         }
      }
      
      if(!exists && touches >= MinTouchCount && g_zone_count < MaxActiveZones) {
         ArrayResize(g_zones, g_zone_count + 1);
         g_zones[g_zone_count].id = g_next_zone_id++;
         g_zones[g_zone_count].type = ZONE_RESISTANCE;
         g_zones[g_zone_count].price_upper = level + zoneWidth;
         g_zones[g_zone_count].price_lower = level - zoneWidth;
         g_zones[g_zone_count].time_created = swingHighTimes[i];
         g_zones[g_zone_count].time_last_touch = swingHighTimes[i];
         g_zones[g_zone_count].touch_count = touches;
         g_zones[g_zone_count].strength = CalculateZoneStrength(touches, atr, i, 0);
         g_zones[g_zone_count].is_broken = false;
         g_zones[g_zone_count].is_active = true;
         g_zone_count++;
      }
   }
   
   // Create support zones from swing lows
   for(int i = 0; i < ArraySize(swingLows); i++) {
      double level = swingLows[i];
      int touches = 1;
      
      for(int j = i + 1; j < ArraySize(swingLows); j++) {
         if(MathAbs(swingLows[j] - level) <= mergeThreshold) {
            level = (level * touches + swingLows[j]) / (touches + 1);
            touches++;
         }
      }
      
      bool exists = false;
      for(int z = 0; z < g_zone_count; z++) {
         if(MathAbs(g_zones[z].MidPrice() - level) <= mergeThreshold) {
            exists = true;
            if(touches > g_zones[z].touch_count) {
               g_zones[z].touch_count = touches;
               g_zones[z].strength = CalculateZoneStrength(touches, atr, i, 0);
            }
            break;
         }
      }
      
      if(!exists && touches >= MinTouchCount && g_zone_count < MaxActiveZones) {
         ArrayResize(g_zones, g_zone_count + 1);
         g_zones[g_zone_count].id = g_next_zone_id++;
         g_zones[g_zone_count].type = ZONE_SUPPORT;
         g_zones[g_zone_count].price_upper = level + zoneWidth;
         g_zones[g_zone_count].price_lower = level - zoneWidth;
         g_zones[g_zone_count].time_created = swingLowTimes[i];
         g_zones[g_zone_count].time_last_touch = swingLowTimes[i];
         g_zones[g_zone_count].touch_count = touches;
         g_zones[g_zone_count].strength = CalculateZoneStrength(touches, atr, i, 0);
         g_zones[g_zone_count].is_broken = false;
         g_zones[g_zone_count].is_active = true;
         g_zone_count++;
      }
   }
   
   Log("Detected " + IntegerToString(g_zone_count) + " S/R zones", "ZONES");
   
   // Draw zones on chart if enabled
   if(DrawZonesOnChart) DrawZones();
}

//+------------------------------------------------------------------+
//| Draw S/R Zones on Chart                                          |
//+------------------------------------------------------------------+
void DrawZones() {
   // Remove old zone objects
   ObjectsDeleteAll(0, "SRZone_");
   
   for(int i = 0; i < g_zone_count; i++) {
      if(!g_zones[i].is_active) continue;
      
      string name = "SRZone_" + IntegerToString(g_zones[i].id);
      color zoneColor = (g_zones[i].type == ZONE_SUPPORT || g_zones[i].type == ZONE_FLIP_SUPPORT) 
                        ? clrGreen : clrRed;
      
      if(g_zones[i].type == ZONE_FLIP_SUPPORT || g_zones[i].type == ZONE_FLIP_RESISTANCE)
         zoneColor = clrGold;  // Flip zones in gold
      
      ObjectCreate(0, name, OBJ_RECTANGLE, 0, 
                   g_zones[i].time_created, g_zones[i].price_upper,
                   TimeCurrent() + PeriodSeconds(HTF_Timeframe) * 20, g_zones[i].price_lower);
      ObjectSetInteger(0, name, OBJPROP_COLOR, zoneColor);
      ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_SOLID);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, name, OBJPROP_FILL, true);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
      ObjectSetString(0, name, OBJPROP_TOOLTIP, 
                      (g_zones[i].type == ZONE_SUPPORT ? "SUPPORT" : "RESISTANCE") +
                      " | Touches: " + IntegerToString(g_zones[i].touch_count) +
                      " | Strength: " + DoubleToString(g_zones[i].strength, 0));
   }
}

//+------------------------------------------------------------------+
//| Check if price is at Support Zone                                |
//+------------------------------------------------------------------+
bool IsAtSupportZone(double price, SRZone &zone) {
   for(int i = 0; i < g_zone_count; i++) {
      if(!g_zones[i].is_active || g_zones[i].is_broken) continue;
      if(g_zones[i].type != ZONE_SUPPORT && g_zones[i].type != ZONE_FLIP_SUPPORT) continue;
      
      double atr = GetATR(h_ltf_atr);
      double approach = atr * 0.5;  // Within half ATR of zone
      
      if(price <= g_zones[i].price_upper + approach && price >= g_zones[i].price_lower - approach) {
         zone = g_zones[i];
         return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Check if price is at Resistance Zone                             |
//+------------------------------------------------------------------+
bool IsAtResistanceZone(double price, SRZone &zone) {
   for(int i = 0; i < g_zone_count; i++) {
      if(!g_zones[i].is_active || g_zones[i].is_broken) continue;
      if(g_zones[i].type != ZONE_RESISTANCE && g_zones[i].type != ZONE_FLIP_RESISTANCE) continue;
      
      double atr = GetATR(h_ltf_atr);
      double approach = atr * 0.5;
      
      if(price >= g_zones[i].price_lower - approach && price <= g_zones[i].price_upper + approach) {
         zone = g_zones[i];
         return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Check for Breakout from Zone                                     |
//+------------------------------------------------------------------+
bool CheckBreakout(bool checkResistance, SRZone &brokenZone) {
   if(!EnableBreakoutEntry) return false;
   
   double close = iClose(_Symbol, LTF_Timeframe, 1);
   double open = iOpen(_Symbol, LTF_Timeframe, 1);
   double high = iHigh(_Symbol, LTF_Timeframe, 1);
   double low = iLow(_Symbol, LTF_Timeframe, 1);
   double atr = GetATR(h_ltf_atr);
   
   if(atr <= 0) return false;
   
   double body = MathAbs(close - open);
   double range = high - low;
   
   // Wick ratio check (reject high-wick candles)
   double wickRatio = (range > 0) ? (range - body) / range : 1.0;
   if(wickRatio > 0.30) return false;  // Too much wick
   
   for(int i = 0; i < g_zone_count; i++) {
      if(!g_zones[i].is_active || g_zones[i].is_broken) continue;
      
      if(checkResistance && (g_zones[i].type == ZONE_RESISTANCE || g_zones[i].type == ZONE_FLIP_RESISTANCE)) {
         // Bullish breakout above resistance
         double penetration = close - g_zones[i].price_upper;
         if(penetration >= atr * BreakoutATR) {
            // Must close in top 30% of candle range
            double closePosition = (range > 0) ? (close - low) / range : 0;
            if(closePosition >= 0.70) {
               brokenZone = g_zones[i];
               g_zones[i].is_broken = true;
               g_zones[i].break_time = TimeCurrent();
               
               // Create flip zone
               AddFlipZone(g_zones[i].MidPrice(), true);
               
               Log(">>> BULLISH BREAKOUT above resistance @ " + DoubleToString(g_zones[i].MidPrice(), g_digits), "BREAKOUT");
               return true;
            }
         }
      }
      
      if(!checkResistance && (g_zones[i].type == ZONE_SUPPORT || g_zones[i].type == ZONE_FLIP_SUPPORT)) {
         // Bearish breakout below support
         double penetration = g_zones[i].price_lower - close;
         if(penetration >= atr * BreakoutATR) {
            double closePosition = (range > 0) ? (high - close) / range : 0;
            if(closePosition >= 0.70) {
               brokenZone = g_zones[i];
               g_zones[i].is_broken = true;
               g_zones[i].break_time = TimeCurrent();
               
               AddFlipZone(g_zones[i].MidPrice(), false);
               
               Log(">>> BEARISH BREAKOUT below support @ " + DoubleToString(g_zones[i].MidPrice(), g_digits), "BREAKOUT");
               return true;
            }
         }
      }
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Add Flip Zone for retest trading                                 |
//+------------------------------------------------------------------+
void AddFlipZone(double level, bool wasResistance) {
   int size = ArraySize(g_flip_zones);
   ArrayResize(g_flip_zones, size + 1);
   
   g_flip_zones[size].level = level;
   g_flip_zones[size].was_resistance = wasResistance;
   g_flip_zones[size].break_time = TimeCurrent();
   g_flip_zones[size].retest_count = 0;
   g_flip_zones[size].is_active = true;
   g_flip_zone_count = size + 1;
   
   Log("Flip zone created @ " + DoubleToString(level, g_digits) + 
       " (was " + (wasResistance ? "Resistance" : "Support") + ")", "FLIP");
}

//+------------------------------------------------------------------+
//| Check for Valid Retest Entry                                     |
//+------------------------------------------------------------------+
bool CheckRetest(bool forBuy, FlipZone &retestZone) {
   if(!EnableRetestEntry) return false;
   
   double price = SymbolInfoDouble(_Symbol, forBuy ? SYMBOL_ASK : SYMBOL_BID);
   double atr = GetATR(h_ltf_atr);
   
   if(atr <= 0) return false;
   
   for(int i = 0; i < g_flip_zone_count; i++) {
      if(!g_flip_zones[i].is_active) continue;
      
      // For BUY: look for former resistance (now support) - was_resistance = true
      // For SELL: look for former support (now resistance) - was_resistance = false
      if(forBuy != g_flip_zones[i].was_resistance) continue;
      
      // Check timing
      int barsSinceBreak = iBarShift(_Symbol, LTF_Timeframe, g_flip_zones[i].break_time);
      if(barsSinceBreak < RetestMinBars || barsSinceBreak > RetestMaxBars) continue;
      
      // Check if price is in retest zone
      double zoneUpper = g_flip_zones[i].level + (atr * RetestZoneATR);
      double zoneLower = g_flip_zones[i].level - (atr * RetestZoneATR * 0.5);
      
      if(forBuy) {
         // Price should be near or slightly above the level
         if(price >= zoneLower && price <= zoneUpper) {
            // Look for rejection candle (pin bar)
            double close = iClose(_Symbol, LTF_Timeframe, 1);
            double open = iOpen(_Symbol, LTF_Timeframe, 1);
            double high = iHigh(_Symbol, LTF_Timeframe, 1);
            double low = iLow(_Symbol, LTF_Timeframe, 1);
            
            double lowerWick = MathMin(open, close) - low;
            double body = MathAbs(close - open);
            
            if(lowerWick > body * 1.5 && close > open) {  // Bullish pin bar
               retestZone = g_flip_zones[i];
               Log(">>> BULLISH RETEST at flip zone @ " + DoubleToString(g_flip_zones[i].level, g_digits), "RETEST");
               return true;
            }
         }
      } else {
         zoneLower = g_flip_zones[i].level - (atr * RetestZoneATR);
         zoneUpper = g_flip_zones[i].level + (atr * RetestZoneATR * 0.5);
         
         if(price >= zoneLower && price <= zoneUpper) {
            double close = iClose(_Symbol, LTF_Timeframe, 1);
            double open = iOpen(_Symbol, LTF_Timeframe, 1);
            double high = iHigh(_Symbol, LTF_Timeframe, 1);
            double low = iLow(_Symbol, LTF_Timeframe, 1);
            
            double upperWick = high - MathMax(open, close);
            double body = MathAbs(close - open);
            
            if(upperWick > body * 1.5 && close < open) {  // Bearish pin bar
               retestZone = g_flip_zones[i];
               Log(">>> BEARISH RETEST at flip zone @ " + DoubleToString(g_flip_zones[i].level, g_digits), "RETEST");
               return true;
            }
         }
      }
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Get HTF Trend Direction (200 EMA)                                |
//+------------------------------------------------------------------+
int GetHTFTrend() {
   double ema[];
   ArraySetAsSeries(ema, true);
   
   if(CopyBuffer(h_htf_ema, 0, 1, 1, ema) <= 0) return 0;
   
   double price = iClose(_Symbol, HTF_Timeframe, 1);
   double atr = GetATR(h_htf_atr);
   
   // Check overextension
   double distance = MathAbs(price - ema[0]);
   if(distance > atr * OverextensionATR) {
      Log("Price overextended from 200 EMA: " + DoubleToString(ToPips(distance), 1) + " pips", "TREND");
      return 0;
   }
   
   // Check ADX if enabled
   if(UseADXFilter) {
      double adx[];
      ArraySetAsSeries(adx, true);
      if(CopyBuffer(h_adx, 0, 1, 1, adx) > 0) {
         if(adx[0] < ADX_Threshold) {
            Log("ADX " + DoubleToString(adx[0], 1) + " < " + DoubleToString(ADX_Threshold, 1) + " - No trend", "TREND");
            return 0;
         }
      }
   }
   
   if(price > ema[0]) {
      Log("HTF UPTREND: Price " + DoubleToString(price, g_digits) + " > EMA " + DoubleToString(ema[0], g_digits), "TREND");
      return 1;
   } else if(price < ema[0]) {
      Log("HTF DOWNTREND: Price " + DoubleToString(price, g_digits) + " < EMA " + DoubleToString(ema[0], g_digits), "TREND");
      return -1;
   }
   
   return 0;
}

//+------------------------------------------------------------------+
//| Detect LTF EMA Crossover                                         |
//+------------------------------------------------------------------+
ENUM_CROSS_TYPE DetectEMACrossover() {
   double fast[], slow[];
   ArraySetAsSeries(fast, true);
   ArraySetAsSeries(slow, true);
   
   if(CopyBuffer(h_ltf_ema_fast, 0, 1, 3, fast) < 3) return CROSS_NONE;
   if(CopyBuffer(h_ltf_ema_slow, 0, 1, 3, slow) < 3) return CROSS_NONE;
   
   // Check for crossover on last closed bar (index 0 = bar 1, index 1 = bar 2)
   bool wasBelowOrEqual = fast[1] <= slow[1];
   bool isAbove = fast[0] > slow[0];
   
   bool wasAboveOrEqual = fast[1] >= slow[1];
   bool isBelow = fast[0] < slow[0];
   
   if(wasBelowOrEqual && isAbove) {
      Log("BULLISH EMA CROSSOVER: Fast " + DoubleToString(fast[0], g_digits) + 
          " crossed above Slow " + DoubleToString(slow[0], g_digits), "CROSS");
      return CROSS_BULLISH;
   }
   
   if(wasAboveOrEqual && isBelow) {
      Log("BEARISH EMA CROSSOVER: Fast " + DoubleToString(fast[0], g_digits) + 
          " crossed below Slow " + DoubleToString(slow[0], g_digits), "CROSS");
      return CROSS_BEARISH;
   }
   
   return CROSS_NONE;
}

//+------------------------------------------------------------------+
//| Check RSI Momentum                                               |
//+------------------------------------------------------------------+
bool CheckRSIMomentum(bool forBuy) {
   if(!UseRSIFilter) return true;
   
   double rsi[];
   ArraySetAsSeries(rsi, true);
   
   if(CopyBuffer(h_rsi, 0, 1, 1, rsi) <= 0) return true;  // If error, don't block
   
   if(forBuy) {
      // For buy: RSI should be above 50 but not overbought
      if(rsi[0] >= RSI_OverboughtLevel) {
         Log("RSI " + DoubleToString(rsi[0], 1) + " overbought - BUY blocked", "RSI");
         return false;
      }
      return rsi[0] > 50;
   } else {
      // For sell: RSI should be below 50 but not oversold
      if(rsi[0] <= RSI_OversoldLevel) {
         Log("RSI " + DoubleToString(rsi[0], 1) + " oversold - SELL blocked", "RSI");
         return false;
      }
      return rsi[0] < 50;
   }
}

//+------------------------------------------------------------------+
//| Calculate Lot Size                                               |
//+------------------------------------------------------------------+
double CalculateLotSize(double slDistance) {
   double balance = account.Balance();
   double riskMoney;
   double slPips = ToPips(slDistance);
   
   if(UseFixedRisk)
      riskMoney = FixedRiskAmount;
   else
      riskMoney = balance * (RiskPercent / 100.0);
   
   double pipValue = GetPipValue(1.0);
   
   if(slPips <= 0 || pipValue <= 0) {
      Log("Invalid SL or pip value for lot calculation", "ERROR");
      return g_minLot;
   }
   
   double lots = riskMoney / (slPips * pipValue);
   lots = MathFloor(lots / g_lotStep) * g_lotStep;
   lots = MathMax(lots, g_minLot);
   lots = MathMin(lots, g_maxLot);
   
   // Margin check
   double marginReq = 0;
   if(OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, lots, SymbolInfoDouble(_Symbol, SYMBOL_ASK), marginReq)) {
      if(marginReq > account.FreeMargin() * 0.8) {
         Log("Reducing lots due to margin constraint", "LOTS");
         lots = g_minLot;
      }
   }
   
   Log("Lot Size: " + DoubleToString(lots, 2) + " | Risk: $" + DoubleToString(riskMoney, 2) + 
       " | SL: " + DoubleToString(slPips, 1) + " pips", "LOTS");
   
   return NormalizeDouble(lots, 2);
}

//+------------------------------------------------------------------+
//| Get Stop Loss Price                                              |
//+------------------------------------------------------------------+
double GetStopLoss(bool isBuy, double entryPrice, SRZone &zone) {
   double atr = GetATR(h_ltf_atr);
   double buffer = ToPrice(SL_ZoneBuffer_Pips) + ToPrice(SL_SpreadBuffer_Pips);
   
   double zoneSL, atrSL;
   
   if(isBuy) {
      zoneSL = zone.price_lower - buffer;
      atrSL = entryPrice - (atr * SL_ATR_Multiplier);
      return MathMin(zoneSL, atrSL);  // Use furthest (more protective)
   } else {
      zoneSL = zone.price_upper + buffer;
      atrSL = entryPrice + (atr * SL_ATR_Multiplier);
      return MathMax(zoneSL, atrSL);
   }
}

//+------------------------------------------------------------------+
//| Get Take Profit Price                                            |
//+------------------------------------------------------------------+
double GetTakeProfit(bool isBuy, double entryPrice, double slPrice) {
   double slDistance = MathAbs(entryPrice - slPrice);
   
   if(TP_UseNextZone) {
      // Find next zone in trade direction
      double nextZone = 0;
      double minDistance = DBL_MAX;
      
      for(int i = 0; i < g_zone_count; i++) {
         if(!g_zones[i].is_active) continue;
         
         if(isBuy && g_zones[i].type == ZONE_RESISTANCE) {
            double distance = g_zones[i].price_lower - entryPrice;
            if(distance > slDistance && distance < minDistance) {
               minDistance = distance;
               nextZone = g_zones[i].price_lower - ToPrice(TP_ZoneBuffer_Pips);
            }
         }
         
         if(!isBuy && g_zones[i].type == ZONE_SUPPORT) {
            double distance = entryPrice - g_zones[i].price_upper;
            if(distance > slDistance && distance < minDistance) {
               minDistance = distance;
               nextZone = g_zones[i].price_upper + ToPrice(TP_ZoneBuffer_Pips);
            }
         }
      }
      
      if(nextZone != 0) {
         Log("TP set to next zone @ " + DoubleToString(nextZone, g_digits), "TP");
         return NormalizeDouble(nextZone, g_digits);
      }
   }
   
   // Fallback to RR ratio
   double tpDistance = slDistance * TP_RiskRewardRatio;
   double tp = isBuy ? entryPrice + tpDistance : entryPrice - tpDistance;
   
   Log("TP set by RR " + DoubleToString(TP_RiskRewardRatio, 1) + ":1 @ " + DoubleToString(tp, g_digits), "TP");
   return NormalizeDouble(tp, g_digits);
}

//+------------------------------------------------------------------+
//| Execute Trade                                                    |
//+------------------------------------------------------------------+
void ExecuteTrade(bool isBuy, SRZone &zone, ENUM_ENTRY_TYPE entryType) {
   Log("==========================================", "TRADE");
   Log(">>> EXECUTING " + (isBuy ? "BUY" : "SELL") + " TRADE <<<", "TRADE");
   Log("Entry Type: " + (entryType == ENTRY_BREAKOUT ? "BREAKOUT" : "RETEST"), "TRADE");
   
   double entry = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = GetStopLoss(isBuy, entry, zone);
   double tp = GetTakeProfit(isBuy, entry, sl);
   
   double slDistance = MathAbs(entry - sl);
   double lots = CalculateLotSize(slDistance);
   
   if(lots < g_minLot) {
      Log("ABORT: Lot size too small", "TRADE");
      return;
   }
   
   // Verify minimum RR
   double tpDistance = MathAbs(tp - entry);
   double actualRR = tpDistance / slDistance;
   if(actualRR < 1.5) {
      Log("ABORT: RR " + DoubleToString(actualRR, 2) + " too low (min 1.5)", "TRADE");
      return;
   }
   
   string comment = "SRZone_" + (isBuy ? "Buy" : "Sell") + "_" + 
                    (entryType == ENTRY_BREAKOUT ? "BO" : "RT");
   
   Log((isBuy ? "BUY" : "SELL") + " Setup: Entry=" + DoubleToString(entry, g_digits) +
       " | SL=" + DoubleToString(sl, g_digits) + " (" + DoubleToString(ToPips(slDistance), 1) + " pips)" +
       " | TP=" + DoubleToString(tp, g_digits) + " (" + DoubleToString(ToPips(tpDistance), 1) + " pips)" +
       " | RR=" + DoubleToString(actualRR, 2), "TRADE");
   
   bool success = false;
   if(isBuy)
      success = trade.Buy(lots, _Symbol, entry, sl, tp, comment);
   else
      success = trade.Sell(lots, _Symbol, entry, sl, tp, comment);
   
   if(success) {
      g_dailyTrades++;
      g_lastSignalTime = TimeCurrent();
      g_lastSignalDirection = isBuy ? 1 : -1;
      
      Log(">>> TRADE EXECUTED! Ticket: " + IntegerToString((int)trade.ResultOrder()) + 
          " | Lots: " + DoubleToString(lots, 2), "SUCCESS");
   } else {
      Log("TRADE FAILED: " + trade.ResultRetcodeDescription(), "ERROR");
   }
   
   Log("==========================================", "TRADE");
}

//+------------------------------------------------------------------+
//| Manage Breakeven                                                 |
//+------------------------------------------------------------------+
void ManageBreakeven() {
   if(!EnableBreakeven) return;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);
      long posType = PositionGetInteger(POSITION_TYPE);
      
      double slDistance = MathAbs(openPrice - currentSL);
      
      // Check if already at breakeven
      double beThreshold = ToPrice(BreakevenBuffer_Pips + 1.0);
      if(MathAbs(currentSL - openPrice) < beThreshold) continue;
      
      double currentPrice = (posType == POSITION_TYPE_BUY) 
                           ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                           : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      
      double profitDistance = (posType == POSITION_TYPE_BUY)
                             ? currentPrice - openPrice
                             : openPrice - currentPrice;
      
      // Move to breakeven at 1:1
      if(profitDistance >= slDistance) {
         double bePrice;
         if(posType == POSITION_TYPE_BUY)
            bePrice = openPrice + ToPrice(BreakevenBuffer_Pips);
         else
            bePrice = openPrice - ToPrice(BreakevenBuffer_Pips);
         
         bePrice = NormalizeDouble(bePrice, g_digits);
         
         if(trade.PositionModify(ticket, bePrice, currentTP)) {
            Log(">>> BREAKEVEN ACTIVATED! Ticket: " + IntegerToString((int)ticket), "BE");
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Manage Trailing Stop                                             |
//+------------------------------------------------------------------+
void ManageTrailingStop() {
   if(!EnableTrailing) return;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);
      long posType = PositionGetInteger(POSITION_TYPE);
      
      double newSL = 0;
      double atr = GetATR(h_ltf_atr);
      double buffer = atr * TrailATR_Multiplier;
      
      if(TrailUseEMA) {
         double ema[];
         ArraySetAsSeries(ema, true);
         if(CopyBuffer(h_ltf_ema_slow, 0, 1, 1, ema) <= 0) continue;
         
         if(posType == POSITION_TYPE_BUY)
            newSL = ema[0] - buffer;
         else
            newSL = ema[0] + buffer;
      } else {
         double currentPrice = (posType == POSITION_TYPE_BUY)
                              ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                              : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         
         if(posType == POSITION_TYPE_BUY)
            newSL = currentPrice - (atr * SL_ATR_Multiplier);
         else
            newSL = currentPrice + (atr * SL_ATR_Multiplier);
      }
      
      newSL = NormalizeDouble(newSL, g_digits);
      
      // Only move SL in profit direction
      bool shouldMove = false;
      if(posType == POSITION_TYPE_BUY && newSL > currentSL && newSL < SymbolInfoDouble(_Symbol, SYMBOL_BID))
         shouldMove = true;
      if(posType == POSITION_TYPE_SELL && newSL < currentSL && newSL > SymbolInfoDouble(_Symbol, SYMBOL_ASK))
         shouldMove = true;
      
      if(shouldMove) {
         if(trade.PositionModify(ticket, newSL, currentTP)) {
            Log("Trailing stop moved to " + DoubleToString(newSL, g_digits), "TRAIL");
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Check if position exists                                         |
//+------------------------------------------------------------------+
bool HasOpenPosition() {
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) == MagicNumber && 
         PositionGetString(POSITION_SYMBOL) == _Symbol)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Main Trading Logic                                               |
//+------------------------------------------------------------------+
void CheckForSignal() {
   // Get HTF trend direction
   int htfTrend = GetHTFTrend();
   if(htfTrend == 0) {
      Log("No clear HTF trend - waiting", "SIGNAL");
      return;
   }
   
   // Detect EMA crossover on LTF
   ENUM_CROSS_TYPE cross = DetectEMACrossover();
   
   double price = SymbolInfoDouble(_Symbol, htfTrend == 1 ? SYMBOL_ASK : SYMBOL_BID);
   SRZone zone;
   FlipZone flipZone;
   
   //--- BUY SIGNAL LOGIC ---
   if(htfTrend == 1) {
      // Method 1: Breakout entry
      if(cross == CROSS_BULLISH && CheckBreakout(true, zone)) {
         if(CheckRSIMomentum(true)) {
            ExecuteTrade(true, zone, ENTRY_BREAKOUT);
            return;
         }
      }
      
      // Method 2: Retest entry
      if(CheckRetest(true, flipZone)) {
         if(cross == CROSS_BULLISH || cross == CROSS_NONE) {  // Allow entry on retest even without fresh cross
            if(CheckRSIMomentum(true)) {
               // Create temp zone for SL calculation
               SRZone tempZone;
               tempZone.price_upper = flipZone.level + GetATR(h_ltf_atr) * 0.5;
               tempZone.price_lower = flipZone.level - GetATR(h_ltf_atr) * 0.5;
               ExecuteTrade(true, tempZone, ENTRY_RETEST);
               return;
            }
         }
      }
      
      // Method 3: Zone bounce entry
      if(cross == CROSS_BULLISH && IsAtSupportZone(price, zone)) {
         if(CheckRSIMomentum(true)) {
            ExecuteTrade(true, zone, ENTRY_RETEST);
            return;
         }
      }
   }
   
   //--- SELL SIGNAL LOGIC ---
   if(htfTrend == -1) {
      // Method 1: Breakout entry
      if(cross == CROSS_BEARISH && CheckBreakout(false, zone)) {
         if(CheckRSIMomentum(false)) {
            ExecuteTrade(false, zone, ENTRY_BREAKOUT);
            return;
         }
      }
      
      // Method 2: Retest entry
      if(CheckRetest(false, flipZone)) {
         if(cross == CROSS_BEARISH || cross == CROSS_NONE) {
            if(CheckRSIMomentum(false)) {
               SRZone tempZone;
               tempZone.price_upper = flipZone.level + GetATR(h_ltf_atr) * 0.5;
               tempZone.price_lower = flipZone.level - GetATR(h_ltf_atr) * 0.5;
               ExecuteTrade(false, tempZone, ENTRY_RETEST);
               return;
            }
         }
      }
      
      // Method 3: Zone bounce entry
      if(cross == CROSS_BEARISH && IsAtResistanceZone(price, zone)) {
         if(CheckRSIMomentum(false)) {
            ExecuteTrade(false, zone, ENTRY_RETEST);
            return;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit() {
   Log("========================================", "INIT");
   Log("S/R Zone Trend EA v1.0 Starting", "INIT");
   Log("HTF: " + EnumToString(HTF_Timeframe) + " 200 EMA | LTF: " + EnumToString(LTF_Timeframe) + " 10/23 EMA", "INIT");
   
   // Setup trade class
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(Slippage);
   trade.SetTypeFilling(ORDER_FILLING_IOC);
   
   // Get symbol specifications
   g_digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   g_point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   g_minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   g_maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   g_lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   
   // Calculate pip metrics
   g_pipSize = GetPipSize();
   g_pipValue = GetPipValue(1.0);
   
   Log("=== SYMBOL SPECIFICATIONS ===", "INIT");
   Log("Symbol: " + _Symbol, "INIT");
   Log("Digits: " + IntegerToString(g_digits) + " | Point: " + DoubleToString(g_point, g_digits), "INIT");
   Log("Pip Size: " + DoubleToString(g_pipSize, g_digits), "INIT");
   Log("Pip Value: $" + DoubleToString(g_pipValue, 4) + " per pip per lot", "INIT");
   
   // Create indicator handles
   h_htf_ema = iMA(_Symbol, HTF_Timeframe, HTF_EMA_Period, 0, MODE_EMA, EMA_Price);
   h_ltf_ema_fast = iMA(_Symbol, LTF_Timeframe, LTF_EMA_Fast, 0, MODE_EMA, EMA_Price);
   h_ltf_ema_slow = iMA(_Symbol, LTF_Timeframe, LTF_EMA_Slow, 0, MODE_EMA, EMA_Price);
   h_htf_atr = iATR(_Symbol, HTF_Timeframe, 14);
   h_ltf_atr = iATR(_Symbol, LTF_Timeframe, 14);
   h_adx = iADX(_Symbol, HTF_Timeframe, ADX_Period);
   h_rsi = iRSI(_Symbol, LTF_Timeframe, RSI_Period, PRICE_CLOSE);
   
   if(h_htf_ema == INVALID_HANDLE || h_ltf_ema_fast == INVALID_HANDLE || 
      h_ltf_ema_slow == INVALID_HANDLE || h_htf_atr == INVALID_HANDLE ||
      h_ltf_atr == INVALID_HANDLE || h_adx == INVALID_HANDLE || h_rsi == INVALID_HANDLE) {
      Log("FAILED to create indicator handles!", "ERROR");
      return INIT_FAILED;
   }
   
   // Initialize state
   g_lastBarTime = 0;
   g_dailyTrades = 0;
   g_dailyResetTime = TimeCurrent();
   g_dailyStartBalance = account.Balance();
   CalculateDailyLimits();
   
   // Initialize zone arrays
   ArrayResize(g_zones, 0);
   ArrayResize(g_flip_zones, 0);
   g_zone_count = 0;
   g_flip_zone_count = 0;
   
   // Initial zone detection
   DetectSRZones();
   
   Log("========================================", "INIT");
   Log("Risk: " + (UseFixedRisk ? "$" + DoubleToString(FixedRiskAmount, 2) : DoubleToString(RiskPercent, 1) + "%"), "INIT");
   Log("Breakout Entry: " + (EnableBreakoutEntry ? "ON" : "OFF") + " | Retest Entry: " + (EnableRetestEntry ? "ON" : "OFF"), "INIT");
   Log("Breakeven: " + (EnableBreakeven ? "ON" : "OFF") + " | Trailing: " + (EnableTrailing ? "ON" : "OFF"), "INIT");
   Log("Session Filter: " + (EnableSessionFilter ? "ON" : "OFF"), "INIT");
   Log("========================================", "INIT");
   
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick() {
   if(!g_botEnabled) return;
   
   // Manage existing positions on every tick
   ManageBreakeven();
   ManageTrailingStop();
   
   // Check for new bar
   datetime currentBarTime = iTime(_Symbol, LTF_Timeframe, 0);
   if(currentBarTime == g_lastBarTime) return;
   g_lastBarTime = currentBarTime;
   
   // New bar processing
   OnNewBar();
}

//+------------------------------------------------------------------+
//| New bar handler                                                  |
//+------------------------------------------------------------------+
void OnNewBar() {
   Log("========== NEW BAR ==========", "BAR");
   
   // Daily reset check
   CheckDailyReset();
   
   // Check daily limits
   if(!CheckDailyLimits()) {
      Log("BLOCKED: Daily limit active", "LIMIT");
      return;
   }
   
   // Check daily trade count
   if(MaxTradesPerDay > 0 && g_dailyTrades >= MaxTradesPerDay) {
      Log("BLOCKED: Max daily trades reached (" + IntegerToString(g_dailyTrades) + ")", "LIMIT");
      return;
   }
   
   // Check spread
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double spreadPips = ToPips(ask - bid);
   if(spreadPips > MaxSpreadPips) {
      Log("BLOCKED: Spread " + DoubleToString(spreadPips, 1) + " > " + DoubleToString(MaxSpreadPips, 1), "SPREAD");
      return;
   }
   
   // Check session
   if(!IsTradingAllowedInSession()) {
      Log("BLOCKED: Outside trading session (" + GetSessionName(g_currentSession) + ")", "SESSION");
      return;
   }
   
   // Check if already have position
   if(HasOpenPosition()) {
      Log("Position already open - managing", "POSITION");
      return;
   }
   
   // Update S/R zones periodically (every 4 hours on H4 bars)
   static datetime lastZoneUpdate = 0;
   if(TimeCurrent() - lastZoneUpdate > PeriodSeconds(PERIOD_H4)) {
      DetectSRZones();
      lastZoneUpdate = TimeCurrent();
   }
   
   // Check for trade signals
   CheckForSignal();
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   // Release indicator handles
   if(h_htf_ema != INVALID_HANDLE) IndicatorRelease(h_htf_ema);
   if(h_ltf_ema_fast != INVALID_HANDLE) IndicatorRelease(h_ltf_ema_fast);
   if(h_ltf_ema_slow != INVALID_HANDLE) IndicatorRelease(h_ltf_ema_slow);
   if(h_htf_atr != INVALID_HANDLE) IndicatorRelease(h_htf_atr);
   if(h_ltf_atr != INVALID_HANDLE) IndicatorRelease(h_ltf_atr);
   if(h_adx != INVALID_HANDLE) IndicatorRelease(h_adx);
   if(h_rsi != INVALID_HANDLE) IndicatorRelease(h_rsi);
   
   // Remove chart objects
   ObjectsDeleteAll(0, "SRZone_");
   
   Log("========================================", "DEINIT");
   Log("Bot stopped. Daily trades: " + IntegerToString(g_dailyTrades), "DEINIT");
   Log("Reason: " + IntegerToString(reason), "DEINIT");
   Log("========================================", "DEINIT");
}
//+------------------------------------------------------------------+