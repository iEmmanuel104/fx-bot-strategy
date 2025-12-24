//+------------------------------------------------------------------+
//|                                        SRZoneTrend_EA_v1.1.mq5   |
//|                   Support/Resistance Zone + MTF EMA Strategy     |
//|                                                       Version 1.1 |
//|  Restricted: XAUUSD & GBPUSD on Exness Standard Account          |
//+------------------------------------------------------------------+
#property copyright "FXBot Trading"
#property link      "https://fxbot.trading"
#property version   "1.10"
#property strict
#property description "Support/Resistance Zone Trading with Multi-Timeframe EMA Analysis"
#property description "H4: 200 EMA for directional bias | M15: 10/23 EMA crossover for entries"
#property description "Symbols: XAUUSD and GBPUSD only (Exness Standard)"
#property description "Features: Breakout & Retest, Zone Visualization, Session Filter"

//+------------------------------------------------------------------+
//| STRATEGY DRAWBACKS & LIMITATIONS (READ BEFORE USING)             |
//+------------------------------------------------------------------+
// 1. LOW TRADE FREQUENCY: This strategy is selective by design.
//    Expect 1-3 trades per day maximum. Quality over quantity.
//    
// 2. MISSED MOVES: Requiring HTF trend alignment means we miss
//    counter-trend bounces that can be profitable.
//    
// 3. ZONE DETECTION LAG: Zones are detected from historical data.
//    Fresh zones (first touch) won't be identified until 2nd touch.
//    
// 4. EMA CROSSOVER DELAY: 10/23 EMA crossover confirms AFTER the
//    move starts. Entry is never at the exact reversal point.
//    
// 5. RETEST TIMING: Ideal retest window (2-20 bars) may miss
//    immediate retests or late retests that still work.
//    
// 6. RANGING MARKETS: ADX filter blocks trades in consolidation,
//    but some ranges offer good S/R bounces.
//    
// 7. NEWS EVENTS: No news filter - high-impact news can blow
//    through zones. Consider manual pause during NFP, FOMC, etc.
//    
// 8. WEEKEND GAPS: Zones can gap over weekend. No gap protection.
//    
// 9. BACKTESTING LIMITATIONS: MT5 backtest uses M15 bars, so
//    intra-bar movements and exact fills may differ from live.
//+------------------------------------------------------------------+

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\AccountInfo.mqh>

//+------------------------------------------------------------------+
//| Input Parameters                                                 |
//+------------------------------------------------------------------+
input group "=== Multi-Timeframe EMA Settings ==="
input ENUM_TIMEFRAMES HTF_Timeframe = PERIOD_H4;         // Higher Timeframe for Bias (H4)
input int      HTF_EMA_Period       = 200;               // HTF EMA Period (Trend Filter)
input ENUM_TIMEFRAMES CrossTF       = PERIOD_H1;         // Timeframe for EMA Crossover (H1)
input ENUM_TIMEFRAMES LTF_Timeframe = PERIOD_M15;        // Lower Timeframe for Entry (M15)
input int      LTF_EMA_Fast         = 10;                // Fast EMA Period (for cross)
input int      LTF_EMA_Slow         = 23;                // Slow EMA Period (for cross)
input ENUM_APPLIED_PRICE EMA_Price  = PRICE_CLOSE;       // Price for EMA calculation

input group "=== Trend Strength Filter ==="
input bool     UseADXFilter         = true;              // Use ADX to filter weak trends
input int      ADX_Period           = 14;                // ADX Period
input double   ADX_Threshold        = 20.0;              // Minimum ADX (lowered from 25 for more trades)
input double   OverextensionATR     = 3.0;               // Max ATR from 200 EMA (raised for more trades)

input group "=== Support/Resistance Zone Detection ==="
input int      ZoneLookbackBars     = 300;               // Bars to look back for S/R zones
input int      SwingStrength_HTF    = 5;                 // H4 swing strength (bars each side)
input int      SwingStrength_LTF    = 3;                 // M15 swing strength (more sensitive)
input double   ZoneWidthATR_HTF     = 0.5;               // H4 zone width (ATR multiplier)
input double   ZoneWidthATR_LTF     = 0.3;               // M15 zone width (tighter)
input int      MinTouchCount        = 2;                 // Minimum touches for valid zone
input int      MaxActiveZones       = 15;                // Maximum zones to track
input double   ZoneMergeATR         = 0.4;               // Merge zones closer than this ATR
input int      ZoneExpiryBars       = 500;               // Zone expires after N bars

input group "=== Entry Mode ==="
input bool     EnableBreakoutEntry  = true;              // Enable breakout entries
input bool     EnableRetestEntry    = true;              // Enable retest entries  
input bool     EnableZoneBounce     = true;              // Enable zone bounce entries (NEW)
input double   BreakoutATR          = 0.8;               // Min ATR for breakout (lowered)
input int      RetestMinBars        = 1;                 // Min bars after breakout (lowered)
input int      RetestMaxBars        = 30;                // Max bars for retest (raised)
input double   RetestZoneATR        = 0.6;               // Retest zone width (raised)
input bool     RequireEMACross      = false;             // Require fresh EMA cross (OFF = more trades)

input group "=== Momentum Confirmation ==="
input bool     UseRSIFilter         = true;              // Use RSI for momentum
input int      RSI_Period           = 14;                // RSI Period
input double   RSI_OverboughtLevel  = 75.0;              // RSI Overbought (raised)
input double   RSI_OversoldLevel    = 25.0;              // RSI Oversold (lowered)

input group "=== Stop Loss Settings ==="
input double   SL_ATR_Multiplier    = 1.5;               // SL = ATR x Multiplier
input int      SL_ZoneBuffer_Pips   = 5;                 // Buffer beyond zone (pips)
input int      SL_SpreadBuffer_Pips = 3;                 // Spread buffer (pips)

input group "=== Take Profit Settings ==="
input bool     TP_UseNextZone       = true;              // TRUE=Use next S/R zone | FALSE=Use fixed RR
input double   TP_RiskRewardRatio   = 2.0;               // Fixed Risk:Reward ratio (used if no zone or disabled)
input double   TP_MinRiskReward     = 1.5;               // Minimum RR to accept trade (0 = no minimum)
input double   TP_ZoneBuffer_Pips   = 5.0;               // Buffer before zone (pips)

input group "=== Breakeven Settings ==="
input bool     EnableBreakeven      = true;              // Move SL to entry at 1:1
input double   BreakevenBuffer_Pips = 1.0;               // Buffer above/below entry

input group "=== Trailing Stop ==="
input bool     EnableTrailing       = true;              // Enable trailing stop
input bool     TrailUseEMA          = true;              // Trail using slow EMA
input double   TrailATR_Multiplier  = 0.3;               // Trail buffer (ATR mult)

input group "=== Risk Management ==="
input bool     UseFixedRisk         = false;             // Use fixed $ risk
input double   RiskPercent          = 1.0;               // Risk per trade (%)
input double   FixedRiskAmount      = 50.0;              // Fixed risk ($)
input int      MagicNumber          = 246811;            // Magic Number
input int      Slippage             = 30;                // Max slippage (points)

input group "=== Daily Limits ==="
input bool     EnableDailyLimits    = true;              // Enable daily limits
input double   MaxDailyLossAmount   = 100.0;             // Max daily loss ($)
input double   MaxDailyLossPercent  = 5.0;               // Max daily loss (%)
input double   DailyProfitTarget    = 200.0;             // Daily profit target ($)
input double   DailyProfitPercent   = 10.0;              // Daily profit target (%)
input bool     StopOnProfitTarget   = false;             // Stop on profit target
input int      MaxTradesPerDay      = 0;                 // Max trades per day (0 = unlimited)

input group "=== Trading Sessions ==="
input bool     EnableSessionFilter  = true;              // Enable session filter
input int      BrokerGMTOffset      = 2;                 // Broker GMT offset

input group "=== Asian Session ==="
input bool     TradeAsianSession    = true;              // Trade Asian
input int      AsianStartHour       = 0;                 // Asian start (GMT)
input int      AsianEndHour         = 9;                 // Asian end (GMT)

input group "=== London Session ==="
input bool     TradeLondonSession   = true;              // Trade London
input int      LondonStartHour      = 7;                 // London start (GMT)
input int      LondonEndHour        = 16;                // London end (GMT)

input group "=== New York Session ==="
input bool     TradeNewYorkSession  = true;              // Trade New York
input int      NewYorkStartHour     = 13;                // NY start (GMT)
input int      NewYorkEndHour       = 22;                // NY end (GMT)

input group "=== Zone Visualization ==="
input bool     DrawZonesOnChart     = true;              // Draw zones on chart
input color    H4_Support_Color     = clrDarkGreen;      // H4 Support zone color
input color    H4_Resistance_Color  = clrDarkRed;        // H4 Resistance zone color
input color    M15_Support_Color    = clrLimeGreen;      // M15 Support zone color
input color    M15_Resistance_Color = clrOrangeRed;      // M15 Resistance zone color
input color    Flip_Zone_Color      = clrGold;           // Flip zone color
input int      H4_Zone_Width        = 2;                 // H4 zone border width
input int      M15_Zone_Width       = 1;                 // M15 zone border width

input group "=== EMA Visualization ==="
input bool     DrawEMAOnChart       = true;              // Draw EMA lines on chart
input color    EMA_200_Color        = clrWhite;          // 200 EMA color (H4)
input color    EMA_Fast_Color       = clrCyan;           // Fast EMA color (10)
input color    EMA_Slow_Color       = clrMagenta;        // Slow EMA color (23)
input int      EMA_Line_Width       = 2;                 // EMA line width

input group "=== Debug ==="
input bool     EnableLogs           = true;              // Enable debug logging
input bool     VerboseLogs          = false;             // Extra verbose logging

//+------------------------------------------------------------------+
//| Enums and Structures                                             |
//+------------------------------------------------------------------+
enum ENUM_ZONE_TYPE {
   ZONE_SUPPORT,
   ZONE_RESISTANCE,
   ZONE_FLIP_SUPPORT,
   ZONE_FLIP_RESISTANCE
};

enum ENUM_ZONE_TIMEFRAME {
   ZONE_TF_H4,
   ZONE_TF_M15
};

enum ENUM_ENTRY_TYPE {
   ENTRY_NONE,
   ENTRY_BREAKOUT,
   ENTRY_RETEST,
   ENTRY_ZONE_BOUNCE
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
   int               id;
   ENUM_ZONE_TYPE    type;
   ENUM_ZONE_TIMEFRAME tf;
   double            price_upper;
   double            price_lower;
   datetime          time_created;
   datetime          time_last_touch;
   int               touch_count;
   double            strength;
   bool              is_broken;
   bool              is_active;
   datetime          break_time;
   
   double MidPrice() { return (price_upper + price_lower) / 2.0; }
   bool   ContainsPrice(double price) { return (price >= price_lower && price <= price_upper); }
};

struct FlipZone {
   double            level;
   bool              was_resistance;
   datetime          break_time;
   int               retest_count;
   bool              is_active;
   ENUM_ZONE_TIMEFRAME tf;
};

//+------------------------------------------------------------------+
//| Global Variables                                                 |
//+------------------------------------------------------------------+
CTrade trade;
CPositionInfo position;
CAccountInfo account;

// Symbol-specific metrics (HARDCODED FOR EXNESS STANDARD)
double g_pipSize = 0.0;
double g_pipValue = 0.0;
double g_point = 0.0;
int    g_digits = 0;
double g_minLot = 0.01;
double g_maxLot = 100.0;
double g_lotStep = 0.01;
bool   g_isGold = false;

// Hardcoded Exness Standard values
double g_maxSpreadPips = 5.0;     // Will be set per symbol
double g_minBodyPips = 3.0;       // Will be set per symbol
double g_beBufferPips = 1.0;      // Will be set per symbol

// Indicator handles
int    h_htf_ema = INVALID_HANDLE;       // H4 200 EMA
int    h_cross_ema_fast = INVALID_HANDLE; // H1 Fast EMA (for crossover)
int    h_cross_ema_slow = INVALID_HANDLE; // H1 Slow EMA (for crossover)
int    h_ltf_ema_fast = INVALID_HANDLE;  // M15 Fast EMA (for visual/entry)
int    h_ltf_ema_slow = INVALID_HANDLE;  // M15 Slow EMA (for visual/entry)
int    h_htf_atr = INVALID_HANDLE;
int    h_ltf_atr = INVALID_HANDLE;
int    h_adx = INVALID_HANDLE;
int    h_adx_plus = INVALID_HANDLE;
int    h_adx_minus = INVALID_HANDLE;
int    h_rsi = INVALID_HANDLE;

// S/R Zone tracking
SRZone   g_zones[];
int      g_zone_count = 0;
int      g_next_zone_id = 1;

// Flip zone tracking
FlipZone g_flip_zones[];
int      g_flip_zone_count = 0;

// State tracking
datetime g_lastBarTime = 0;
datetime g_lastHTFBarTime = 0;
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

// EMA state tracking (for H1 crossover detection)
bool     g_emaBullish = false;    // H1 Fast > Slow
bool     g_emaBearish = false;    // H1 Fast < Slow
datetime g_lastCrossTime = 0;
int      g_lastCrossDirection = 0;  // 1 = bullish cross, -1 = bearish cross

//+------------------------------------------------------------------+
//| Logging function                                                 |
//+------------------------------------------------------------------+
void Log(string msg, string cat = "INFO") {
   if(EnableLogs) Print("[", cat, "] ", msg);
}

void LogVerbose(string msg, string cat = "DEBUG") {
   if(EnableLogs && VerboseLogs) Print("[", cat, "] ", msg);
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
//| Initialize Symbol-Specific Parameters (EXNESS STANDARD)          |
//+------------------------------------------------------------------+
void InitSymbolParams() {
   g_isGold = IsGold();
   
   if(g_isGold) {
      //=== XAUUSD on Exness Standard ===
      // Digits: 2 (e.g., 1920.50)
      // Point: 0.01
      // Pip Size: 0.01 (1 pip = $0.01 move = 1 point)
      // Pip Value: ~$1.00 per pip per 1.0 lot
      // Typical Spread: 1.6-2.5 pips (can spike to 5-10 during news)
      // Max Spread for EA: 35 pips (to allow volatile sessions)
      
      g_pipSize = 0.01;
      g_pipValue = 1.0;           // $1.00 per pip per lot
      g_maxSpreadPips = 35.0;     // Allow high spreads during volatility
      g_minBodyPips = 5.0;        // Min candle body for patterns
      g_beBufferPips = 3.0;       // Breakeven buffer
      
      Log("=== XAUUSD (GOLD) MODE ===", "CONFIG");
      Log("Pip Size: 0.01 | Pip Value: $1.00/lot | Max Spread: 35 pips", "CONFIG");
      
   } else {
      //=== GBPUSD on Exness Standard ===
      // Digits: 5 (e.g., 1.26785)
      // Point: 0.00001
      // Pip Size: 0.0001 (1 pip = 0.0001 move = 10 points)
      // Pip Value: ~$10.00 per pip per 1.0 lot
      // Typical Spread: 0.3-1.0 pips
      // Max Spread for EA: 5 pips
      
      g_pipSize = 0.0001;
      g_pipValue = 10.0;          // $10.00 per pip per lot
      g_maxSpreadPips = 5.0;      // Tight spread control
      g_minBodyPips = 3.0;        // Min candle body for patterns
      g_beBufferPips = 0.5;       // Breakeven buffer
      
      Log("=== GBPUSD (FOREX) MODE ===", "CONFIG");
      Log("Pip Size: 0.0001 | Pip Value: $10.00/lot | Max Spread: 5 pips", "CONFIG");
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
//| Get Pip Value (uses hardcoded values)                            |
//+------------------------------------------------------------------+
double GetPipValue(double lots = 1.0) {
   return g_pipValue * lots;
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
//| Get session name                                                 |
//+------------------------------------------------------------------+
string GetSessionName(SESSION_TYPE session) {
   switch(session) {
      case SESSION_ASIAN: return "ASIAN";
      case SESSION_LONDON: return "LONDON";
      case SESSION_NEWYORK: return "NEW_YORK";
      case SESSION_OVERLAP_TOKYO_LONDON: return "TOKYO-LONDON";
      case SESSION_OVERLAP_LONDON_NY: return "LONDON-NY";
      default: return "OFF_HOURS";
   }
}

//+------------------------------------------------------------------+
//| Check if trading allowed in session                              |
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
   
   double lossAmt = MaxDailyLossAmount;
   double lossPct = g_dailyStartBalance * (MaxDailyLossPercent / 100.0);
   g_dailyMaxLoss = (MaxDailyLossAmount > 0 && MaxDailyLossPercent > 0) ? MathMax(lossAmt, lossPct) :
                    (MaxDailyLossAmount > 0) ? lossAmt : lossPct;
   
   double profitAmt = DailyProfitTarget;
   double profitPct = g_dailyStartBalance * (DailyProfitPercent / 100.0);
   g_dailyProfitGoal = (DailyProfitTarget > 0 && DailyProfitPercent > 0) ? MathMax(profitAmt, profitPct) :
                       (DailyProfitTarget > 0) ? profitAmt : profitPct;
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
         Log("!!! DAILY LOSS LIMIT: $" + DoubleToString(g_dailyPnL, 2), "LIMIT");
      }
      return false;
   }
   
   if(StopOnProfitTarget && g_dailyProfitGoal > 0 && g_dailyPnL >= g_dailyProfitGoal) {
      if(!g_dailyProfitTargetHit) {
         g_dailyProfitTargetHit = true;
         Log("*** DAILY PROFIT TARGET: $" + DoubleToString(g_dailyPnL, 2), "TARGET");
      }
      return false;
   }
   
   return true;
}

//+------------------------------------------------------------------+
//| Daily reset check                                                |
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
//| Get ATR value                                                    |
//+------------------------------------------------------------------+
double GetATR(int handle, int shift = 1) {
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(handle, 0, shift, 1, atr) <= 0) return 0;
   return atr[0];
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
//| Calculate Zone Strength Score                                    |
//+------------------------------------------------------------------+
double CalculateZoneStrength(int touchCount, int age, ENUM_ZONE_TIMEFRAME tf) {
   double score = 0;
   
   // Touch count (40% weight)
   if(touchCount >= 4) score += 40;
   else if(touchCount >= 3) score += 30;
   else if(touchCount >= 2) score += 20;
   else score += 10;
   
   // Recency (30% weight)
   if(age <= 50) score += 30;
   else if(age <= 100) score += 25;
   else if(age <= 200) score += 20;
   else if(age <= 300) score += 15;
   else score += 10;
   
   // Timeframe weight (30% weight) - H4 zones are stronger
   if(tf == ZONE_TF_H4) score += 30;
   else score += 15;
   
   return MathMin(score, 100);
}

//+------------------------------------------------------------------+
//| Detect S/R Zones for a specific timeframe                        |
//+------------------------------------------------------------------+
void DetectZonesForTimeframe(ENUM_TIMEFRAMES tf, ENUM_ZONE_TIMEFRAME zoneTF, int swingStrength, double widthATR) {
   double high[], low[], close[];
   datetime time[];
   
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   ArraySetAsSeries(close, true);
   ArraySetAsSeries(time, true);
   
   int bars = MathMin(ZoneLookbackBars, iBars(_Symbol, tf) - swingStrength - 1);
   
   if(CopyHigh(_Symbol, tf, 0, bars, high) <= 0) return;
   if(CopyLow(_Symbol, tf, 0, bars, low) <= 0) return;
   if(CopyClose(_Symbol, tf, 0, bars, close) <= 0) return;
   if(CopyTime(_Symbol, tf, 0, bars, time) <= 0) return;
   
   int atrHandle = (tf == HTF_Timeframe) ? h_htf_atr : h_ltf_atr;
   double atr = GetATR(atrHandle);
   if(atr <= 0) return;
   
   double zoneWidth = atr * widthATR;
   double mergeThreshold = atr * ZoneMergeATR;
   
   // Detect swing highs (resistance)
   for(int i = swingStrength; i < bars - swingStrength; i++) {
      if(!IsSwingHigh(i, swingStrength, high)) continue;
      
      double level = high[i];
      int touches = 1;
      
      // Count nearby swing highs
      for(int j = i + 1; j < bars - swingStrength; j++) {
         if(IsSwingHigh(j, swingStrength, high) && MathAbs(high[j] - level) <= mergeThreshold) {
            level = (level * touches + high[j]) / (touches + 1);
            touches++;
         }
      }
      
      // Check if zone already exists
      bool exists = false;
      for(int z = 0; z < g_zone_count; z++) {
         if(MathAbs(g_zones[z].MidPrice() - level) <= mergeThreshold) {
            exists = true;
            if(touches > g_zones[z].touch_count && zoneTF == g_zones[z].tf) {
               g_zones[z].touch_count = touches;
               g_zones[z].strength = CalculateZoneStrength(touches, i, zoneTF);
            }
            break;
         }
      }
      
      if(!exists && touches >= MinTouchCount && g_zone_count < MaxActiveZones) {
         ArrayResize(g_zones, g_zone_count + 1);
         g_zones[g_zone_count].id = g_next_zone_id++;
         g_zones[g_zone_count].type = ZONE_RESISTANCE;
         g_zones[g_zone_count].tf = zoneTF;
         g_zones[g_zone_count].price_upper = level + zoneWidth;
         g_zones[g_zone_count].price_lower = level - zoneWidth;
         g_zones[g_zone_count].time_created = time[i];
         g_zones[g_zone_count].time_last_touch = time[i];
         g_zones[g_zone_count].touch_count = touches;
         g_zones[g_zone_count].strength = CalculateZoneStrength(touches, i, zoneTF);
         g_zones[g_zone_count].is_broken = false;
         g_zones[g_zone_count].is_active = true;
         g_zone_count++;
      }
   }
   
   // Detect swing lows (support)
   for(int i = swingStrength; i < bars - swingStrength; i++) {
      if(!IsSwingLow(i, swingStrength, low)) continue;
      
      double level = low[i];
      int touches = 1;
      
      for(int j = i + 1; j < bars - swingStrength; j++) {
         if(IsSwingLow(j, swingStrength, low) && MathAbs(low[j] - level) <= mergeThreshold) {
            level = (level * touches + low[j]) / (touches + 1);
            touches++;
         }
      }
      
      bool exists = false;
      for(int z = 0; z < g_zone_count; z++) {
         if(MathAbs(g_zones[z].MidPrice() - level) <= mergeThreshold) {
            exists = true;
            if(touches > g_zones[z].touch_count && zoneTF == g_zones[z].tf) {
               g_zones[z].touch_count = touches;
               g_zones[z].strength = CalculateZoneStrength(touches, i, zoneTF);
            }
            break;
         }
      }
      
      if(!exists && touches >= MinTouchCount && g_zone_count < MaxActiveZones) {
         ArrayResize(g_zones, g_zone_count + 1);
         g_zones[g_zone_count].id = g_next_zone_id++;
         g_zones[g_zone_count].type = ZONE_SUPPORT;
         g_zones[g_zone_count].tf = zoneTF;
         g_zones[g_zone_count].price_upper = level + zoneWidth;
         g_zones[g_zone_count].price_lower = level - zoneWidth;
         g_zones[g_zone_count].time_created = time[i];
         g_zones[g_zone_count].time_last_touch = time[i];
         g_zones[g_zone_count].touch_count = touches;
         g_zones[g_zone_count].strength = CalculateZoneStrength(touches, i, zoneTF);
         g_zones[g_zone_count].is_broken = false;
         g_zones[g_zone_count].is_active = true;
         g_zone_count++;
      }
   }
}

//+------------------------------------------------------------------+
//| Detect all S/R Zones (H4 and M15)                                |
//+------------------------------------------------------------------+
void DetectSRZones() {
   // Clear existing zones
   ArrayResize(g_zones, 0);
   g_zone_count = 0;
   
   // Detect H4 zones (stronger, used for bias)
   DetectZonesForTimeframe(HTF_Timeframe, ZONE_TF_H4, SwingStrength_HTF, ZoneWidthATR_HTF);
   int h4Count = g_zone_count;
   
   // Detect M15 zones (for precise entries)
   DetectZonesForTimeframe(LTF_Timeframe, ZONE_TF_M15, SwingStrength_LTF, ZoneWidthATR_LTF);
   int m15Count = g_zone_count - h4Count;
   
   Log("Zones detected: H4=" + IntegerToString(h4Count) + " | M15=" + IntegerToString(m15Count) + 
       " | Total=" + IntegerToString(g_zone_count), "ZONES");
   
   if(DrawZonesOnChart) DrawZones();
}

//+------------------------------------------------------------------+
//| Draw S/R Zones on Chart with clear differentiation               |
//+------------------------------------------------------------------+
void DrawZones() {
   // Remove old zone objects
   ObjectsDeleteAll(0, "SRZ_");
   
   for(int i = 0; i < g_zone_count; i++) {
      if(!g_zones[i].is_active) continue;
      
      // Create unique name with TF prefix for easy identification
      string tfPrefix = (g_zones[i].tf == ZONE_TF_H4) ? "H4" : "M15";
      string typeStr = "";
      color zoneColor = clrGray;  // Default initialization
      int borderWidth = 1;
      ENUM_LINE_STYLE borderStyle = STYLE_SOLID;
      
      // Determine color and style based on type and timeframe
      switch(g_zones[i].type) {
         case ZONE_SUPPORT:
            zoneColor = (g_zones[i].tf == ZONE_TF_H4) ? H4_Support_Color : M15_Support_Color;
            typeStr = "SUP";
            break;
         case ZONE_RESISTANCE:
            zoneColor = (g_zones[i].tf == ZONE_TF_H4) ? H4_Resistance_Color : M15_Resistance_Color;
            typeStr = "RES";
            break;
         case ZONE_FLIP_SUPPORT:
            zoneColor = Flip_Zone_Color;
            typeStr = "FLIP_SUP";
            break;
         case ZONE_FLIP_RESISTANCE:
            zoneColor = Flip_Zone_Color;
            typeStr = "FLIP_RES";
            break;
      }
      
      borderWidth = (g_zones[i].tf == ZONE_TF_H4) ? H4_Zone_Width : M15_Zone_Width;
      borderStyle = (g_zones[i].tf == ZONE_TF_H4) ? STYLE_SOLID : STYLE_DOT;
      
      string name = "SRZ_" + tfPrefix + "_" + typeStr + "_" + IntegerToString(g_zones[i].id);
      
      // Draw rectangle for zone
      ObjectCreate(0, name, OBJ_RECTANGLE, 0,
                   g_zones[i].time_created, g_zones[i].price_upper,
                   TimeCurrent() + PeriodSeconds(HTF_Timeframe) * 50, g_zones[i].price_lower);
      ObjectSetInteger(0, name, OBJPROP_COLOR, zoneColor);
      ObjectSetInteger(0, name, OBJPROP_STYLE, borderStyle);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, borderWidth);
      ObjectSetInteger(0, name, OBJPROP_FILL, false);  // NO FILL - outline only
      ObjectSetInteger(0, name, OBJPROP_BACK, false);  // Draw in foreground
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      
      // Create label for zone
      string labelName = name + "_LBL";
      string labelText = tfPrefix + " " + typeStr + " [" + IntegerToString(g_zones[i].touch_count) + "T] " +
                         "Str:" + IntegerToString((int)g_zones[i].strength);
      
      ObjectCreate(0, labelName, OBJ_TEXT, 0,
                   TimeCurrent() + PeriodSeconds(PERIOD_H1) * 2, g_zones[i].MidPrice());
      ObjectSetString(0, labelName, OBJPROP_TEXT, labelText);
      ObjectSetInteger(0, labelName, OBJPROP_COLOR, zoneColor);
      ObjectSetInteger(0, labelName, OBJPROP_FONTSIZE, (g_zones[i].tf == ZONE_TF_H4) ? 10 : 8);
      ObjectSetString(0, labelName, OBJPROP_FONT, "Arial Bold");
      ObjectSetInteger(0, labelName, OBJPROP_ANCHOR, ANCHOR_LEFT);
      
      // Tooltip with full details
      string tooltip = tfPrefix + " " + typeStr + "\n" +
                       "Touches: " + IntegerToString(g_zones[i].touch_count) + "\n" +
                       "Strength: " + DoubleToString(g_zones[i].strength, 0) + "/100\n" +
                       "Upper: " + DoubleToString(g_zones[i].price_upper, g_digits) + "\n" +
                       "Lower: " + DoubleToString(g_zones[i].price_lower, g_digits) + "\n" +
                       "Created: " + TimeToString(g_zones[i].time_created);
      ObjectSetString(0, name, OBJPROP_TOOLTIP, tooltip);
   }
   
   // Draw legend
   DrawLegend();
}

//+------------------------------------------------------------------+
//| Draw Legend on Chart                                             |
//+------------------------------------------------------------------+
void DrawLegend() {
   int x = 10, y = 50;
   string prefix = "SRZ_LEG_";
   
   ObjectsDeleteAll(0, prefix);
   
   // Title
   ObjectCreate(0, prefix + "TITLE", OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, prefix + "TITLE", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, prefix + "TITLE", OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, prefix + "TITLE", OBJPROP_YDISTANCE, y);
   ObjectSetString(0, prefix + "TITLE", OBJPROP_TEXT, "=== S/R ZONES LEGEND ===");
   ObjectSetInteger(0, prefix + "TITLE", OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, prefix + "TITLE", OBJPROP_FONTSIZE, 10);
   
   // H4 Support
   y += 20;
   ObjectCreate(0, prefix + "H4SUP", OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, prefix + "H4SUP", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, prefix + "H4SUP", OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, prefix + "H4SUP", OBJPROP_YDISTANCE, y);
   ObjectSetString(0, prefix + "H4SUP", OBJPROP_TEXT, "■ H4 SUPPORT (Thick Solid)");
   ObjectSetInteger(0, prefix + "H4SUP", OBJPROP_COLOR, H4_Support_Color);
   ObjectSetInteger(0, prefix + "H4SUP", OBJPROP_FONTSIZE, 9);
   
   // H4 Resistance
   y += 15;
   ObjectCreate(0, prefix + "H4RES", OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, prefix + "H4RES", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, prefix + "H4RES", OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, prefix + "H4RES", OBJPROP_YDISTANCE, y);
   ObjectSetString(0, prefix + "H4RES", OBJPROP_TEXT, "■ H4 RESISTANCE (Thick Solid)");
   ObjectSetInteger(0, prefix + "H4RES", OBJPROP_COLOR, H4_Resistance_Color);
   ObjectSetInteger(0, prefix + "H4RES", OBJPROP_FONTSIZE, 9);
   
   // M15 Support
   y += 15;
   ObjectCreate(0, prefix + "M15SUP", OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, prefix + "M15SUP", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, prefix + "M15SUP", OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, prefix + "M15SUP", OBJPROP_YDISTANCE, y);
   ObjectSetString(0, prefix + "M15SUP", OBJPROP_TEXT, "□ M15 SUPPORT (Thin Dotted)");
   ObjectSetInteger(0, prefix + "M15SUP", OBJPROP_COLOR, M15_Support_Color);
   ObjectSetInteger(0, prefix + "M15SUP", OBJPROP_FONTSIZE, 9);
   
   // M15 Resistance
   y += 15;
   ObjectCreate(0, prefix + "M15RES", OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, prefix + "M15RES", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, prefix + "M15RES", OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, prefix + "M15RES", OBJPROP_YDISTANCE, y);
   ObjectSetString(0, prefix + "M15RES", OBJPROP_TEXT, "□ M15 RESISTANCE (Thin Dotted)");
   ObjectSetInteger(0, prefix + "M15RES", OBJPROP_COLOR, M15_Resistance_Color);
   ObjectSetInteger(0, prefix + "M15RES", OBJPROP_FONTSIZE, 9);
   
   // Flip Zones
   y += 15;
   ObjectCreate(0, prefix + "FLIP", OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, prefix + "FLIP", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, prefix + "FLIP", OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, prefix + "FLIP", OBJPROP_YDISTANCE, y);
   ObjectSetString(0, prefix + "FLIP", OBJPROP_TEXT, "◆ FLIP ZONES (Gold)");
   ObjectSetInteger(0, prefix + "FLIP", OBJPROP_COLOR, Flip_Zone_Color);
   ObjectSetInteger(0, prefix + "FLIP", OBJPROP_FONTSIZE, 9);
}

//+------------------------------------------------------------------+
//| Draw EMA Lines on Chart                                          |
//+------------------------------------------------------------------+
void DrawEMALines() {
   if(!DrawEMAOnChart) return;
   
   // Delete old EMA lines
   ObjectsDeleteAll(0, "EMA_LINE_");
   
   int barsToShow = 200;  // Number of bars to draw
   
   // Get EMA values
   double ema200[], emaFast[], emaSlow[];
   ArraySetAsSeries(ema200, true);
   ArraySetAsSeries(emaFast, true);
   ArraySetAsSeries(emaSlow, true);
   
   datetime time[];
   ArraySetAsSeries(time, true);
   
   // Copy time array from chart timeframe
   if(CopyTime(_Symbol, PERIOD_CURRENT, 0, barsToShow, time) <= 0) return;
   
   // Copy H4 200 EMA values (need to map to current chart timeframe)
   if(CopyBuffer(h_htf_ema, 0, 0, barsToShow, ema200) <= 0) return;
   
   // Copy H1 Fast/Slow EMA values for crossover display
   if(CopyBuffer(h_cross_ema_fast, 0, 0, barsToShow, emaFast) <= 0) return;
   if(CopyBuffer(h_cross_ema_slow, 0, 0, barsToShow, emaSlow) <= 0) return;
   
   // Draw 200 EMA line (from H4)
   string name200 = "EMA_LINE_200";
   ObjectCreate(0, name200, OBJ_TREND, 0, time[barsToShow-1], ema200[barsToShow-1], time[0], ema200[0]);
   ObjectSetInteger(0, name200, OBJPROP_COLOR, EMA_200_Color);
   ObjectSetInteger(0, name200, OBJPROP_WIDTH, EMA_Line_Width);
   ObjectSetInteger(0, name200, OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(0, name200, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, name200, OBJPROP_BACK, false);
   ObjectSetString(0, name200, OBJPROP_TOOLTIP, "H4 200 EMA: " + DoubleToString(ema200[0], g_digits));
   
   // Draw segment-based EMA lines for better visualization
   for(int i = 0; i < barsToShow - 1; i++) {
      // 200 EMA segments
      string seg200 = "EMA_LINE_200_" + IntegerToString(i);
      ObjectCreate(0, seg200, OBJ_TREND, 0, time[i+1], ema200[i+1], time[i], ema200[i]);
      ObjectSetInteger(0, seg200, OBJPROP_COLOR, EMA_200_Color);
      ObjectSetInteger(0, seg200, OBJPROP_WIDTH, EMA_Line_Width);
      ObjectSetInteger(0, seg200, OBJPROP_RAY_RIGHT, false);
      ObjectSetInteger(0, seg200, OBJPROP_BACK, false);
      ObjectSetInteger(0, seg200, OBJPROP_SELECTABLE, false);
      
      // Fast EMA segments (H1)
      string segFast = "EMA_LINE_FAST_" + IntegerToString(i);
      ObjectCreate(0, segFast, OBJ_TREND, 0, time[i+1], emaFast[i+1], time[i], emaFast[i]);
      ObjectSetInteger(0, segFast, OBJPROP_COLOR, EMA_Fast_Color);
      ObjectSetInteger(0, segFast, OBJPROP_WIDTH, EMA_Line_Width);
      ObjectSetInteger(0, segFast, OBJPROP_RAY_RIGHT, false);
      ObjectSetInteger(0, segFast, OBJPROP_BACK, false);
      ObjectSetInteger(0, segFast, OBJPROP_SELECTABLE, false);
      
      // Slow EMA segments (H1)
      string segSlow = "EMA_LINE_SLOW_" + IntegerToString(i);
      ObjectCreate(0, segSlow, OBJ_TREND, 0, time[i+1], emaSlow[i+1], time[i], emaSlow[i]);
      ObjectSetInteger(0, segSlow, OBJPROP_COLOR, EMA_Slow_Color);
      ObjectSetInteger(0, segSlow, OBJPROP_WIDTH, EMA_Line_Width);
      ObjectSetInteger(0, segSlow, OBJPROP_RAY_RIGHT, false);
      ObjectSetInteger(0, segSlow, OBJPROP_BACK, false);
      ObjectSetInteger(0, segSlow, OBJPROP_SELECTABLE, false);
   }
   
   // Add EMA info to legend
   DrawEMALegend();
}

//+------------------------------------------------------------------+
//| Draw EMA Legend                                                  |
//+------------------------------------------------------------------+
void DrawEMALegend() {
   int x = 10, y = 170;
   string prefix = "EMA_LEG_";
   
   ObjectsDeleteAll(0, prefix);
   
   // Get current EMA values
   double ema200[], emaFast[], emaSlow[];
   ArraySetAsSeries(ema200, true);
   ArraySetAsSeries(emaFast, true);
   ArraySetAsSeries(emaSlow, true);
   
   CopyBuffer(h_htf_ema, 0, 1, 1, ema200);
   CopyBuffer(h_cross_ema_fast, 0, 1, 1, emaFast);
   CopyBuffer(h_cross_ema_slow, 0, 1, 1, emaSlow);
   
   // Title
   ObjectCreate(0, prefix + "TITLE", OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, prefix + "TITLE", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, prefix + "TITLE", OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, prefix + "TITLE", OBJPROP_YDISTANCE, y);
   ObjectSetString(0, prefix + "TITLE", OBJPROP_TEXT, "=== EMA LINES ===");
   ObjectSetInteger(0, prefix + "TITLE", OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, prefix + "TITLE", OBJPROP_FONTSIZE, 10);
   
   // 200 EMA
   y += 18;
   ObjectCreate(0, prefix + "200", OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, prefix + "200", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, prefix + "200", OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, prefix + "200", OBJPROP_YDISTANCE, y);
   ObjectSetString(0, prefix + "200", OBJPROP_TEXT, "— H4 200 EMA: " + DoubleToString(ema200[0], g_digits));
   ObjectSetInteger(0, prefix + "200", OBJPROP_COLOR, EMA_200_Color);
   ObjectSetInteger(0, prefix + "200", OBJPROP_FONTSIZE, 9);
   
   // Fast EMA
   y += 15;
   ObjectCreate(0, prefix + "FAST", OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, prefix + "FAST", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, prefix + "FAST", OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, prefix + "FAST", OBJPROP_YDISTANCE, y);
   ObjectSetString(0, prefix + "FAST", OBJPROP_TEXT, "— H1 " + IntegerToString(LTF_EMA_Fast) + " EMA: " + DoubleToString(emaFast[0], g_digits));
   ObjectSetInteger(0, prefix + "FAST", OBJPROP_COLOR, EMA_Fast_Color);
   ObjectSetInteger(0, prefix + "FAST", OBJPROP_FONTSIZE, 9);
   
   // Slow EMA
   y += 15;
   ObjectCreate(0, prefix + "SLOW", OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, prefix + "SLOW", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, prefix + "SLOW", OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, prefix + "SLOW", OBJPROP_YDISTANCE, y);
   ObjectSetString(0, prefix + "SLOW", OBJPROP_TEXT, "— H1 " + IntegerToString(LTF_EMA_Slow) + " EMA: " + DoubleToString(emaSlow[0], g_digits));
   ObjectSetInteger(0, prefix + "SLOW", OBJPROP_COLOR, EMA_Slow_Color);
   ObjectSetInteger(0, prefix + "SLOW", OBJPROP_FONTSIZE, 9);
   
   // Cross status
   y += 15;
   string crossStatus = (g_lastCrossDirection == 1) ? "BULLISH" : (g_lastCrossDirection == -1) ? "BEARISH" : "NONE";
   color crossColor = (g_lastCrossDirection == 1) ? clrLime : (g_lastCrossDirection == -1) ? clrRed : clrGray;
   ObjectCreate(0, prefix + "CROSS", OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, prefix + "CROSS", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, prefix + "CROSS", OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, prefix + "CROSS", OBJPROP_YDISTANCE, y);
   ObjectSetString(0, prefix + "CROSS", OBJPROP_TEXT, "► H1 Cross: " + crossStatus);
   ObjectSetInteger(0, prefix + "CROSS", OBJPROP_COLOR, crossColor);
   ObjectSetInteger(0, prefix + "CROSS", OBJPROP_FONTSIZE, 9);
}

//+------------------------------------------------------------------+
//| Check if price is at Support Zone                                |
//+------------------------------------------------------------------+
bool IsAtSupportZone(double price, SRZone &zone, bool preferH4 = true) {
   double atr = GetATR(h_ltf_atr);
   double approach = atr * 0.5;
   
   // First check H4 zones if preferred
   if(preferH4) {
      for(int i = 0; i < g_zone_count; i++) {
         if(!g_zones[i].is_active || g_zones[i].is_broken) continue;
         if(g_zones[i].type != ZONE_SUPPORT && g_zones[i].type != ZONE_FLIP_SUPPORT) continue;
         if(g_zones[i].tf != ZONE_TF_H4) continue;
         
         if(price <= g_zones[i].price_upper + approach && price >= g_zones[i].price_lower - approach) {
            zone = g_zones[i];
            return true;
         }
      }
   }
   
   // Then check M15 zones
   for(int i = 0; i < g_zone_count; i++) {
      if(!g_zones[i].is_active || g_zones[i].is_broken) continue;
      if(g_zones[i].type != ZONE_SUPPORT && g_zones[i].type != ZONE_FLIP_SUPPORT) continue;
      if(preferH4 && g_zones[i].tf == ZONE_TF_H4) continue;  // Already checked
      
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
bool IsAtResistanceZone(double price, SRZone &zone, bool preferH4 = true) {
   double atr = GetATR(h_ltf_atr);
   double approach = atr * 0.5;
   
   if(preferH4) {
      for(int i = 0; i < g_zone_count; i++) {
         if(!g_zones[i].is_active || g_zones[i].is_broken) continue;
         if(g_zones[i].type != ZONE_RESISTANCE && g_zones[i].type != ZONE_FLIP_RESISTANCE) continue;
         if(g_zones[i].tf != ZONE_TF_H4) continue;
         
         if(price >= g_zones[i].price_lower - approach && price <= g_zones[i].price_upper + approach) {
            zone = g_zones[i];
            return true;
         }
      }
   }
   
   for(int i = 0; i < g_zone_count; i++) {
      if(!g_zones[i].is_active || g_zones[i].is_broken) continue;
      if(g_zones[i].type != ZONE_RESISTANCE && g_zones[i].type != ZONE_FLIP_RESISTANCE) continue;
      if(preferH4 && g_zones[i].tf == ZONE_TF_H4) continue;
      
      if(price >= g_zones[i].price_lower - approach && price <= g_zones[i].price_upper + approach) {
         zone = g_zones[i];
         return true;
      }
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Add Flip Zone                                                    |
//+------------------------------------------------------------------+
void AddFlipZone(double level, bool wasResistance, ENUM_ZONE_TIMEFRAME tf) {
   int size = ArraySize(g_flip_zones);
   ArrayResize(g_flip_zones, size + 1);
   
   g_flip_zones[size].level = level;
   g_flip_zones[size].was_resistance = wasResistance;
   g_flip_zones[size].break_time = TimeCurrent();
   g_flip_zones[size].retest_count = 0;
   g_flip_zones[size].is_active = true;
   g_flip_zones[size].tf = tf;
   g_flip_zone_count = size + 1;
   
   Log("Flip zone @ " + DoubleToString(level, g_digits) + " (was " + 
       (wasResistance ? "RES" : "SUP") + ") TF=" + (tf == ZONE_TF_H4 ? "H4" : "M15"), "FLIP");
}

//+------------------------------------------------------------------+
//| Check for Breakout                                               |
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
   double wickRatio = (range > 0) ? (range - body) / range : 1.0;
   
   if(wickRatio > 0.35) return false;  // Relaxed from 0.30
   
   for(int i = 0; i < g_zone_count; i++) {
      if(!g_zones[i].is_active || g_zones[i].is_broken) continue;
      
      if(checkResistance && (g_zones[i].type == ZONE_RESISTANCE || g_zones[i].type == ZONE_FLIP_RESISTANCE)) {
         double penetration = close - g_zones[i].price_upper;
         if(penetration >= atr * BreakoutATR) {
            double closePosition = (range > 0) ? (close - low) / range : 0;
            if(closePosition >= 0.65) {  // Relaxed from 0.70
               brokenZone = g_zones[i];
               g_zones[i].is_broken = true;
               g_zones[i].break_time = TimeCurrent();
               AddFlipZone(g_zones[i].MidPrice(), true, g_zones[i].tf);
               Log(">>> BULLISH BREAKOUT @ " + DoubleToString(g_zones[i].MidPrice(), g_digits) + 
                   " TF=" + (g_zones[i].tf == ZONE_TF_H4 ? "H4" : "M15"), "BREAKOUT");
               return true;
            }
         }
      }
      
      if(!checkResistance && (g_zones[i].type == ZONE_SUPPORT || g_zones[i].type == ZONE_FLIP_SUPPORT)) {
         double penetration = g_zones[i].price_lower - close;
         if(penetration >= atr * BreakoutATR) {
            double closePosition = (range > 0) ? (high - close) / range : 0;
            if(closePosition >= 0.65) {
               brokenZone = g_zones[i];
               g_zones[i].is_broken = true;
               g_zones[i].break_time = TimeCurrent();
               AddFlipZone(g_zones[i].MidPrice(), false, g_zones[i].tf);
               Log(">>> BEARISH BREAKOUT @ " + DoubleToString(g_zones[i].MidPrice(), g_digits) + 
                   " TF=" + (g_zones[i].tf == ZONE_TF_H4 ? "H4" : "M15"), "BREAKOUT");
               return true;
            }
         }
      }
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Check for Valid Retest                                           |
//+------------------------------------------------------------------+
bool CheckRetest(bool forBuy, FlipZone &retestZone) {
   if(!EnableRetestEntry) return false;
   
   double price = SymbolInfoDouble(_Symbol, forBuy ? SYMBOL_ASK : SYMBOL_BID);
   double atr = GetATR(h_ltf_atr);
   
   if(atr <= 0) return false;
   
   for(int i = 0; i < g_flip_zone_count; i++) {
      if(!g_flip_zones[i].is_active) continue;
      if(forBuy != g_flip_zones[i].was_resistance) continue;
      
      int barsSinceBreak = iBarShift(_Symbol, LTF_Timeframe, g_flip_zones[i].break_time);
      if(barsSinceBreak < RetestMinBars || barsSinceBreak > RetestMaxBars) continue;
      
      double zoneUpper = g_flip_zones[i].level + (atr * RetestZoneATR);
      double zoneLower = g_flip_zones[i].level - (atr * RetestZoneATR);
      
      if(price >= zoneLower && price <= zoneUpper) {
         double close = iClose(_Symbol, LTF_Timeframe, 1);
         double open = iOpen(_Symbol, LTF_Timeframe, 1);
         double high = iHigh(_Symbol, LTF_Timeframe, 1);
         double low = iLow(_Symbol, LTF_Timeframe, 1);
         
         if(forBuy) {
            double lowerWick = MathMin(open, close) - low;
            double body = MathAbs(close - open);
            if((lowerWick > body * 1.2 && close > open) || close > open) {  // Relaxed pin bar requirement
               retestZone = g_flip_zones[i];
               Log(">>> BULLISH RETEST @ " + DoubleToString(g_flip_zones[i].level, g_digits), "RETEST");
               return true;
            }
         } else {
            double upperWick = high - MathMax(open, close);
            double body = MathAbs(close - open);
            if((upperWick > body * 1.2 && close < open) || close < open) {
               retestZone = g_flip_zones[i];
               Log(">>> BEARISH RETEST @ " + DoubleToString(g_flip_zones[i].level, g_digits), "RETEST");
               return true;
            }
         }
      }
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Get HTF Trend Direction                                          |
//+------------------------------------------------------------------+
int GetHTFTrend() {
   double ema[];
   ArraySetAsSeries(ema, true);
   
   if(CopyBuffer(h_htf_ema, 0, 1, 1, ema) <= 0) return 0;
   
   double price = iClose(_Symbol, HTF_Timeframe, 1);
   double atr = GetATR(h_htf_atr);
   
   double distance = MathAbs(price - ema[0]);
   if(distance > atr * OverextensionATR) {
      LogVerbose("Overextended: " + DoubleToString(ToPips(distance), 1) + " pips from 200 EMA", "TREND");
      return 0;
   }
   
   if(UseADXFilter) {
      double adx[];
      ArraySetAsSeries(adx, true);
      if(CopyBuffer(h_adx, 0, 1, 1, adx) > 0) {
         if(adx[0] < ADX_Threshold) {
            LogVerbose("ADX " + DoubleToString(adx[0], 1) + " < " + DoubleToString(ADX_Threshold, 1), "TREND");
            return 0;
         }
      }
   }
   
   if(price > ema[0]) return 1;
   if(price < ema[0]) return -1;
   
   return 0;
}

//+------------------------------------------------------------------+
//| Update EMA State (H1 crossover detection)                        |
//+------------------------------------------------------------------+
void UpdateEMAState() {
   double fast[], slow[];
   ArraySetAsSeries(fast, true);
   ArraySetAsSeries(slow, true);
   
   // Use H1 (CrossTF) EMAs for crossover detection
   if(CopyBuffer(h_cross_ema_fast, 0, 1, 2, fast) < 2) return;
   if(CopyBuffer(h_cross_ema_slow, 0, 1, 2, slow) < 2) return;
   
   bool wasBullish = g_emaBullish;
   bool wasBearish = g_emaBearish;
   
   g_emaBullish = (fast[0] > slow[0]);
   g_emaBearish = (fast[0] < slow[0]);
   
   // Detect fresh crossover on H1
   if(!wasBullish && g_emaBullish) {
      g_lastCrossTime = TimeCurrent();
      g_lastCrossDirection = 1;
      Log("H1 BULLISH CROSS: Fast " + DoubleToString(fast[0], g_digits) + " > Slow " + DoubleToString(slow[0], g_digits), "CROSS");
   }
   if(!wasBearish && g_emaBearish) {
      g_lastCrossTime = TimeCurrent();
      g_lastCrossDirection = -1;
      Log("H1 BEARISH CROSS: Fast " + DoubleToString(fast[0], g_digits) + " < Slow " + DoubleToString(slow[0], g_digits), "CROSS");
   }
}

//+------------------------------------------------------------------+
//| Check EMA Alignment                                              |
//| H1 cross gives signal, M15 EMA alignment confirms entry          |
//+------------------------------------------------------------------+
bool CheckEMAAlignment(bool forBuy) {
   // Check H1 crossover direction
   if(forBuy && g_lastCrossDirection != 1) {
      LogVerbose("No H1 bullish cross active", "EMA");
      return false;
   }
   if(!forBuy && g_lastCrossDirection != -1) {
      LogVerbose("No H1 bearish cross active", "EMA");
      return false;
   }
   
   // Check how recent the H1 cross was (in H1 bars)
   if(RequireEMACross) {
      int barsSinceCross = iBarShift(_Symbol, CrossTF, g_lastCrossTime);
      if(barsSinceCross > 10) {  // Cross must be within last 10 H1 bars
         LogVerbose("H1 cross too old: " + IntegerToString(barsSinceCross) + " bars ago", "EMA");
         return false;
      }
   }
   
   // Check M15 EMA alignment for entry confirmation
   double fastM15[], slowM15[];
   ArraySetAsSeries(fastM15, true);
   ArraySetAsSeries(slowM15, true);
   
   if(CopyBuffer(h_ltf_ema_fast, 0, 1, 1, fastM15) < 1) return false;
   if(CopyBuffer(h_ltf_ema_slow, 0, 1, 1, slowM15) < 1) return false;
   
   // M15 EMAs should align with H1 cross direction
   if(forBuy && fastM15[0] <= slowM15[0]) {
      LogVerbose("M15 EMAs not bullish aligned yet", "EMA");
      return false;
   }
   if(!forBuy && fastM15[0] >= slowM15[0]) {
      LogVerbose("M15 EMAs not bearish aligned yet", "EMA");
      return false;
   }
   
   Log("EMA Confirmed: H1 cross " + (forBuy ? "BULLISH" : "BEARISH") + " + M15 aligned", "EMA");
   return true;
}

//+------------------------------------------------------------------+
//| Check RSI Momentum                                               |
//+------------------------------------------------------------------+
bool CheckRSIMomentum(bool forBuy) {
   if(!UseRSIFilter) return true;
   
   double rsi[];
   ArraySetAsSeries(rsi, true);
   
   if(CopyBuffer(h_rsi, 0, 1, 1, rsi) <= 0) return true;
   
   if(forBuy) {
      if(rsi[0] >= RSI_OverboughtLevel) {
         LogVerbose("RSI " + DoubleToString(rsi[0], 1) + " overbought", "RSI");
         return false;
      }
      return rsi[0] > 45;  // Relaxed from 50
   } else {
      if(rsi[0] <= RSI_OversoldLevel) {
         LogVerbose("RSI " + DoubleToString(rsi[0], 1) + " oversold", "RSI");
         return false;
      }
      return rsi[0] < 55;  // Relaxed from 50
   }
}

//+------------------------------------------------------------------+
//| Calculate Lot Size                                               |
//+------------------------------------------------------------------+
double CalculateLotSize(double slDistance) {
   double balance = account.Balance();
   double riskMoney = UseFixedRisk ? FixedRiskAmount : balance * (RiskPercent / 100.0);
   double slPips = ToPips(slDistance);
   double pipValue = GetPipValue(1.0);
   
   if(slPips <= 0 || pipValue <= 0) {
      Log("Invalid SL/pip value", "ERROR");
      return g_minLot;
   }
   
   double lots = riskMoney / (slPips * pipValue);
   lots = MathFloor(lots / g_lotStep) * g_lotStep;
   lots = MathMax(lots, g_minLot);
   lots = MathMin(lots, g_maxLot);
   
   double marginReq = 0;
   if(OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, lots, SymbolInfoDouble(_Symbol, SYMBOL_ASK), marginReq)) {
      if(marginReq > account.FreeMargin() * 0.8) {
         lots = g_minLot;
      }
   }
   
   Log("Lots: " + DoubleToString(lots, 2) + " | Risk: $" + DoubleToString(riskMoney, 2) + 
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
      return NormalizeDouble(MathMin(zoneSL, atrSL), g_digits);
   } else {
      zoneSL = zone.price_upper + buffer;
      atrSL = entryPrice + (atr * SL_ATR_Multiplier);
      return NormalizeDouble(MathMax(zoneSL, atrSL), g_digits);
   }
}

//+------------------------------------------------------------------+
//| Get Take Profit Price                                            |
//| Mode 1: TP_UseNextZone = true  -> Use next S/R zone as target    |
//| Mode 2: TP_UseNextZone = false -> Use fixed RR from settings     |
//+------------------------------------------------------------------+
double GetTakeProfit(bool isBuy, double entryPrice, double slPrice) {
   double slDistance = MathAbs(entryPrice - slPrice);
   double tpDistance = slDistance * TP_RiskRewardRatio;  // Default from settings
   
   // MODE 1: Strategy-based TP (use next S/R zone)
   if(TP_UseNextZone) {
      double bestZoneTP = 0;
      double bestDistance = DBL_MAX;
      double minRRForZone = (TP_MinRiskReward > 0) ? TP_MinRiskReward : 1.0;  // At least 1:1 if no min set
      
      for(int i = 0; i < g_zone_count; i++) {
         if(!g_zones[i].is_active) continue;
         
         if(isBuy && (g_zones[i].type == ZONE_RESISTANCE || g_zones[i].type == ZONE_FLIP_RESISTANCE)) {
            double zoneTarget = g_zones[i].price_lower - ToPrice(TP_ZoneBuffer_Pips);
            double distance = zoneTarget - entryPrice;
            
            // Must be above entry and provide minimum RR
            if(distance > slDistance * minRRForZone && distance < bestDistance) {
               bestDistance = distance;
               bestZoneTP = zoneTarget;
            }
         }
         
         if(!isBuy && (g_zones[i].type == ZONE_SUPPORT || g_zones[i].type == ZONE_FLIP_SUPPORT)) {
            double zoneTarget = g_zones[i].price_upper + ToPrice(TP_ZoneBuffer_Pips);
            double distance = entryPrice - zoneTarget;
            
            // Must be below entry and provide minimum RR
            if(distance > slDistance * minRRForZone && distance < bestDistance) {
               bestDistance = distance;
               bestZoneTP = zoneTarget;
            }
         }
      }
      
      // Use zone-based TP if found
      if(bestZoneTP > 0) {
         Log("TP Mode: NEXT ZONE @ " + DoubleToString(bestZoneTP, g_digits) + 
             " | RR: " + DoubleToString(bestDistance / slDistance, 2) + ":1", "TP");
         return NormalizeDouble(bestZoneTP, g_digits);
      }
      
      // No suitable zone found - fall back to fixed RR
      Log("TP Mode: No zone found, using FIXED RR " + DoubleToString(TP_RiskRewardRatio, 1) + ":1", "TP");
   } else {
      // MODE 2: Fixed RR from settings
      Log("TP Mode: FIXED RR " + DoubleToString(TP_RiskRewardRatio, 1) + ":1", "TP");
   }
   
   // Calculate TP using fixed RR ratio from settings
   double tp = isBuy ? entryPrice + tpDistance : entryPrice - tpDistance;
   return NormalizeDouble(tp, g_digits);
}

//+------------------------------------------------------------------+
//| Execute Trade                                                    |
//+------------------------------------------------------------------+
void ExecuteTrade(bool isBuy, SRZone &zone, ENUM_ENTRY_TYPE entryType) {
   Log("==========================================", "TRADE");
   Log(">>> " + (isBuy ? "BUY" : "SELL") + " SIGNAL <<<", "TRADE");
   
   string entryTypeStr = "UNKNOWN";
   switch(entryType) {
      case ENTRY_BREAKOUT: entryTypeStr = "BREAKOUT"; break;
      case ENTRY_RETEST: entryTypeStr = "RETEST"; break;
      case ENTRY_ZONE_BOUNCE: entryTypeStr = "ZONE_BOUNCE"; break;
   }
   Log("Entry Type: " + entryTypeStr + " | Zone TF: " + (zone.tf == ZONE_TF_H4 ? "H4" : "M15"), "TRADE");
   
   double entry = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = GetStopLoss(isBuy, entry, zone);
   double tp = GetTakeProfit(isBuy, entry, sl);
   
   double slDistance = MathAbs(entry - sl);
   double lots = CalculateLotSize(slDistance);
   
   if(lots < g_minLot) {
      Log("ABORT: Lot size too small", "TRADE");
      return;
   }
   
   double tpDistance = MathAbs(tp - entry);
   double actualRR = tpDistance / slDistance;
   
   // Check minimum RR if enabled (0 = no minimum check)
   if(TP_MinRiskReward > 0 && actualRR < TP_MinRiskReward) {
      Log("ABORT: RR " + DoubleToString(actualRR, 2) + " < Min " + DoubleToString(TP_MinRiskReward, 2), "TRADE");
      return;
   }
   
   string comment = "SRZ_" + (isBuy ? "B" : "S") + "_" + StringSubstr(entryTypeStr, 0, 2);
   
   Log((isBuy ? "BUY" : "SELL") + ": Entry=" + DoubleToString(entry, g_digits) +
       " | SL=" + DoubleToString(sl, g_digits) + " (" + DoubleToString(ToPips(slDistance), 1) + "p)" +
       " | TP=" + DoubleToString(tp, g_digits) + " (" + DoubleToString(ToPips(tpDistance), 1) + "p)" +
       " | RR=" + DoubleToString(actualRR, 2), "TRADE");
   
   bool success = isBuy ? trade.Buy(lots, _Symbol, entry, sl, tp, comment) :
                          trade.Sell(lots, _Symbol, entry, sl, tp, comment);
   
   if(success) {
      g_dailyTrades++;
      Log(">>> EXECUTED! Ticket: " + IntegerToString((int)trade.ResultOrder()), "SUCCESS");
   } else {
      Log("FAILED: " + trade.ResultRetcodeDescription(), "ERROR");
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
      double beThreshold = ToPrice(g_beBufferPips + 1.0);
      
      if(MathAbs(currentSL - openPrice) < beThreshold) continue;
      
      double currentPrice = (posType == POSITION_TYPE_BUY) ?
                           SymbolInfoDouble(_Symbol, SYMBOL_BID) :
                           SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      
      double profitDistance = (posType == POSITION_TYPE_BUY) ?
                             currentPrice - openPrice :
                             openPrice - currentPrice;
      
      if(profitDistance >= slDistance) {
         double bePrice = (posType == POSITION_TYPE_BUY) ?
                         openPrice + ToPrice(g_beBufferPips) :
                         openPrice - ToPrice(g_beBufferPips);
         bePrice = NormalizeDouble(bePrice, g_digits);
         
         if(trade.PositionModify(ticket, bePrice, currentTP)) {
            Log(">>> BREAKEVEN @ " + DoubleToString(bePrice, g_digits), "BE");
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
         
         newSL = (posType == POSITION_TYPE_BUY) ? ema[0] - buffer : ema[0] + buffer;
      } else {
         double currentPrice = (posType == POSITION_TYPE_BUY) ?
                              SymbolInfoDouble(_Symbol, SYMBOL_BID) :
                              SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         newSL = (posType == POSITION_TYPE_BUY) ?
                currentPrice - (atr * SL_ATR_Multiplier) :
                currentPrice + (atr * SL_ATR_Multiplier);
      }
      
      newSL = NormalizeDouble(newSL, g_digits);
      
      bool shouldMove = false;
      if(posType == POSITION_TYPE_BUY && newSL > currentSL && newSL < SymbolInfoDouble(_Symbol, SYMBOL_BID))
         shouldMove = true;
      if(posType == POSITION_TYPE_SELL && newSL < currentSL && newSL > SymbolInfoDouble(_Symbol, SYMBOL_ASK))
         shouldMove = true;
      
      if(shouldMove) {
         if(trade.PositionModify(ticket, newSL, currentTP)) {
            Log("Trail SL -> " + DoubleToString(newSL, g_digits), "TRAIL");
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
//| Main Signal Check                                                |
//+------------------------------------------------------------------+
void CheckForSignal() {
   int htfTrend = GetHTFTrend();
   if(htfTrend == 0) {
      LogVerbose("No HTF trend", "SIGNAL");
      return;
   }
   
   Log("HTF Trend: " + (htfTrend == 1 ? "BULLISH" : "BEARISH"), "SIGNAL");
   
   double price = SymbolInfoDouble(_Symbol, htfTrend == 1 ? SYMBOL_ASK : SYMBOL_BID);
   SRZone zone;
   FlipZone flipZone;
   
   //--- BUY SIGNALS ---
   if(htfTrend == 1) {
      // Check EMA alignment
      if(!CheckEMAAlignment(true)) {
         LogVerbose("EMA not bullish aligned", "SIGNAL");
         return;
      }
      
      // Check RSI
      if(!CheckRSIMomentum(true)) {
         LogVerbose("RSI not confirming buy", "SIGNAL");
         return;
      }
      
      // Method 1: Breakout
      if(EnableBreakoutEntry && CheckBreakout(true, zone)) {
         ExecuteTrade(true, zone, ENTRY_BREAKOUT);
         return;
      }
      
      // Method 2: Retest
      if(EnableRetestEntry && CheckRetest(true, flipZone)) {
         SRZone tempZone;
         tempZone.price_upper = flipZone.level + GetATR(h_ltf_atr) * 0.5;
         tempZone.price_lower = flipZone.level - GetATR(h_ltf_atr) * 0.5;
         tempZone.tf = flipZone.tf;
         ExecuteTrade(true, tempZone, ENTRY_RETEST);
         return;
      }
      
      // Method 3: Zone Bounce
      if(EnableZoneBounce && IsAtSupportZone(price, zone, true)) {
         ExecuteTrade(true, zone, ENTRY_ZONE_BOUNCE);
         return;
      }
   }
   
   //--- SELL SIGNALS ---
   if(htfTrend == -1) {
      if(!CheckEMAAlignment(false)) {
         LogVerbose("EMA not bearish aligned", "SIGNAL");
         return;
      }
      
      if(!CheckRSIMomentum(false)) {
         LogVerbose("RSI not confirming sell", "SIGNAL");
         return;
      }
      
      if(EnableBreakoutEntry && CheckBreakout(false, zone)) {
         ExecuteTrade(false, zone, ENTRY_BREAKOUT);
         return;
      }
      
      if(EnableRetestEntry && CheckRetest(false, flipZone)) {
         SRZone tempZone;
         tempZone.price_upper = flipZone.level + GetATR(h_ltf_atr) * 0.5;
         tempZone.price_lower = flipZone.level - GetATR(h_ltf_atr) * 0.5;
         tempZone.tf = flipZone.tf;
         ExecuteTrade(false, tempZone, ENTRY_RETEST);
         return;
      }
      
      if(EnableZoneBounce && IsAtResistanceZone(price, zone, true)) {
         ExecuteTrade(false, zone, ENTRY_ZONE_BOUNCE);
         return;
      }
   }
   
   LogVerbose("No valid entry found", "SIGNAL");
}

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit() {
   Log("========================================", "INIT");
   Log("S/R Zone Trend EA v1.1", "INIT");
   Log("XAUUSD & GBPUSD Only (Exness Standard)", "INIT");
   Log("H4: 200 EMA Bias | H1: 10/23 Cross | M15: Entry", "INIT");
   
   // Validate symbol
   if(!IsSymbolAllowed()) {
      Alert("This EA only works on XAUUSD or GBPUSD!");
      return INIT_FAILED;
   }
   
   // Setup trade class
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(Slippage);
   trade.SetTypeFilling(ORDER_FILLING_IOC);
   
   // Get broker symbol specs
   g_digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   g_point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   g_minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   g_maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   g_lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   
   // Initialize hardcoded Exness values
   InitSymbolParams();
   
   // Create indicator handles
   h_htf_ema = iMA(_Symbol, HTF_Timeframe, HTF_EMA_Period, 0, MODE_EMA, EMA_Price);
   h_cross_ema_fast = iMA(_Symbol, CrossTF, LTF_EMA_Fast, 0, MODE_EMA, EMA_Price);  // H1 Fast EMA for cross
   h_cross_ema_slow = iMA(_Symbol, CrossTF, LTF_EMA_Slow, 0, MODE_EMA, EMA_Price);  // H1 Slow EMA for cross
   h_ltf_ema_fast = iMA(_Symbol, LTF_Timeframe, LTF_EMA_Fast, 0, MODE_EMA, EMA_Price);  // M15 Fast EMA
   h_ltf_ema_slow = iMA(_Symbol, LTF_Timeframe, LTF_EMA_Slow, 0, MODE_EMA, EMA_Price);  // M15 Slow EMA
   h_htf_atr = iATR(_Symbol, HTF_Timeframe, 14);
   h_ltf_atr = iATR(_Symbol, LTF_Timeframe, 14);
   h_adx = iADX(_Symbol, HTF_Timeframe, ADX_Period);
   h_rsi = iRSI(_Symbol, LTF_Timeframe, RSI_Period, PRICE_CLOSE);
   
   if(h_htf_ema == INVALID_HANDLE || h_cross_ema_fast == INVALID_HANDLE ||
      h_cross_ema_slow == INVALID_HANDLE || h_ltf_ema_fast == INVALID_HANDLE ||
      h_ltf_ema_slow == INVALID_HANDLE || h_htf_atr == INVALID_HANDLE ||
      h_ltf_atr == INVALID_HANDLE || h_adx == INVALID_HANDLE || h_rsi == INVALID_HANDLE) {
      Log("Failed to create indicators!", "ERROR");
      return INIT_FAILED;
   }
   
   // Initialize state
   g_lastBarTime = 0;
   g_lastHTFBarTime = 0;
   g_dailyTrades = 0;
   g_dailyResetTime = TimeCurrent();
   g_dailyStartBalance = account.Balance();
   CalculateDailyLimits();
   
   ArrayResize(g_zones, 0);
   ArrayResize(g_flip_zones, 0);
   g_zone_count = 0;
   g_flip_zone_count = 0;
   
   // Detect initial zones
   DetectSRZones();
   
   // Initial EMA state
   UpdateEMAState();
   
   // Draw initial EMA lines
   DrawEMALines();
   
   Log("========================================", "INIT");
   Log("Symbol: " + _Symbol + " | Pip Value: $" + DoubleToString(g_pipValue, 2), "INIT");
   Log("Risk: " + (UseFixedRisk ? "$" + DoubleToString(FixedRiskAmount, 2) : DoubleToString(RiskPercent, 1) + "%"), "INIT");
   Log("Entry Modes: BO=" + (EnableBreakoutEntry ? "ON" : "OFF") + 
       " | RT=" + (EnableRetestEntry ? "ON" : "OFF") +
       " | ZB=" + (EnableZoneBounce ? "ON" : "OFF"), "INIT");
   Log("RequireEMACross: " + (RequireEMACross ? "YES (strict)" : "NO (relaxed)"), "INIT");
   Log("========================================", "INIT");
   
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick() {
   if(!g_botEnabled) return;
   
   ManageBreakeven();
   ManageTrailingStop();
   
   datetime currentBarTime = iTime(_Symbol, LTF_Timeframe, 0);
   if(currentBarTime == g_lastBarTime) return;
   g_lastBarTime = currentBarTime;
   
   OnNewBar();
}

//+------------------------------------------------------------------+
//| New bar handler                                                  |
//+------------------------------------------------------------------+
void OnNewBar() {
   Log("--- New M15 Bar ---", "BAR");
   
   CheckDailyReset();
   
   if(!CheckDailyLimits()) return;
   
   if(MaxTradesPerDay > 0 && g_dailyTrades >= MaxTradesPerDay) {
      Log("Max daily trades reached", "LIMIT");
      return;
   }
   
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double spreadPips = ToPips(ask - bid);
   if(spreadPips > g_maxSpreadPips) {
      Log("Spread " + DoubleToString(spreadPips, 1) + " > " + DoubleToString(g_maxSpreadPips, 1), "SPREAD");
      return;
   }
   
   if(!IsTradingAllowedInSession()) {
      LogVerbose("Outside session: " + GetSessionName(g_currentSession), "SESSION");
      return;
   }
   
   if(HasOpenPosition()) {
      LogVerbose("Position open - managing", "POSITION");
      return;
   }
   
   // Update zones on H4 bar change
   datetime htfBarTime = iTime(_Symbol, HTF_Timeframe, 0);
   if(htfBarTime != g_lastHTFBarTime) {
      g_lastHTFBarTime = htfBarTime;
      DetectSRZones();
   }
   
   // Update EMA state
   UpdateEMAState();
   
   // Draw EMA lines on chart
   DrawEMALines();
   
   // Check for signals
   CheckForSignal();
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   if(h_htf_ema != INVALID_HANDLE) IndicatorRelease(h_htf_ema);
   if(h_cross_ema_fast != INVALID_HANDLE) IndicatorRelease(h_cross_ema_fast);
   if(h_cross_ema_slow != INVALID_HANDLE) IndicatorRelease(h_cross_ema_slow);
   if(h_ltf_ema_fast != INVALID_HANDLE) IndicatorRelease(h_ltf_ema_fast);
   if(h_ltf_ema_slow != INVALID_HANDLE) IndicatorRelease(h_ltf_ema_slow);
   if(h_htf_atr != INVALID_HANDLE) IndicatorRelease(h_htf_atr);
   if(h_ltf_atr != INVALID_HANDLE) IndicatorRelease(h_ltf_atr);
   if(h_adx != INVALID_HANDLE) IndicatorRelease(h_adx);
   if(h_rsi != INVALID_HANDLE) IndicatorRelease(h_rsi);
   
   // Delete all chart objects
   ObjectsDeleteAll(0, "SRZ_");
   ObjectsDeleteAll(0, "EMA_LINE_");
   ObjectsDeleteAll(0, "EMA_LEG_");
   
   Log("========================================", "DEINIT");
   Log("Stopped. Trades today: " + IntegerToString(g_dailyTrades), "DEINIT");
}
//+------------------------------------------------------------------+