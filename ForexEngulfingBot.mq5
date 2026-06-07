//+------------------------------------------------------------------+
//|                                         ForexEngulfingBot.mq5    |
//|                        EMA Crossover & Retest Multi-Symbol EA    |
//|                                                       Version 1.0|
//|                    SIGNAL BROADCAST MODE - For Multi-Account Use |
//|  Supports: GBPUSD, GBPJPY                                        |
//|  Strategy: H1 Engulfing + EMA -> M5 Retest + Engulfing -> Entry  |
//|  Features: Dual Trade (1:1 + 1:2 RR), ATR-based SL, 2 Batches    |
//+------------------------------------------------------------------+
#property copyright "FXBot Trading"
#property link      "https://fxbot.trading"
#property version   "1.10"
#property strict
#property description "Forex EMA 10/23 Engulfing Strategy v1.1"
#property description "NEW: EMA trend direction filter (H1 + M5 alignment)"
#property description "Supports: GBPUSD, GBPJPY"
#property description "H1: Engulfing candle closes above/below EMA lines"
#property description "M5: Wait for EMA retest + Engulfing confirmation"
#property description "Entry: Dual trades (1:1 RR + 1:2 RR)"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\AccountInfo.mqh>

//+------------------------------------------------------------------+
//| Fixed Strategy Parameters (not configurable)                     |
//+------------------------------------------------------------------+
#define HTF_TIMEFRAME PERIOD_H1
#define LTF_TIMEFRAME PERIOD_M5
#define EMA_FAST_PERIOD 10
#define EMA_SLOW_PERIOD 23
#define EMA_APPLIED_PRICE PRICE_MEDIAN
#define MAX_POSITIONS_PER_SYMBOL 10
#define MAX_TOTAL_POSITIONS 20
#define MARGIN_BUFFER_PERCENT 10.0

//+------------------------------------------------------------------+
//| Input Parameters                                                 |
//+------------------------------------------------------------------+
input group "=== Broadcast Mode (Multi-Account) ==="
input bool     BroadcastMode = true;                      // Enable Signal Broadcast Mode
input string   BroadcastURL = "https://fxbot-server-production.up.railway.app/api/signals/ea"; // Broadcast API Endpoint
input string   BroadcastAPIKey = "SET_IN_MT5_INPUTS"; // Broadcast API Key
input bool     ExecuteOnMaster = true;                    // Also execute trades on THIS account

input group "=== Server Configuration ==="
input string   ServerURL = "https://fxbot-server-production.up.railway.app/api";
input int      MagicNumber = 247891;                      // Magic Number (same as Gold bot)
input bool     EnableServerConnection = true;             // Connect to server
input int      HeartbeatIntervalSec = 30;                 // Heartbeat interval (seconds)

input group "=== Symbol Selection ==="
input bool     TradeGBPUSD = true;                        // Trade GBPUSD
input bool     TradeGBPJPY = true;                        // Trade GBPJPY

input group "=== Risk Management ==="
input bool     UsePercentageRisk = true;                  // TRUE = % of balance | FALSE = Fixed $
input double   RiskPercent = 1.0;                         // Risk per trade (each of the 2 trades)
input double   RiskDollars = 100.0;                       // Fixed dollar risk per trade
input double   MinRiskPercent = 1.0;                      // MINIMUM risk % floor
input double   MaxRiskPercent = 5.0;                      // MAXIMUM risk % ceiling
input double   RR_Trade1 = 1.0;                           // Risk:Reward for Trade 1
input double   RR_Trade2 = 2.0;                           // Risk:Reward for Trade 2
input bool     AutoBreakeven = true;                      // Auto-breakeven Trade 2 when Trade 1 hits TP
input int      BreakevenBufferPips = 5;                   // Breakeven buffer in pips (profit lock)

input group "=== ATR Stop Loss Settings ==="
input int      ATR_Period = 14;                           // ATR Period for SL calculation
input double   ATR_Multiplier = 1.5;                      // ATR Multiplier for SL
input int      SpreadBufferPips = 3;                      // Additional spread buffer (pips)
input int      MinSLPips = 10;                            // Minimum SL (pips)
input int      MaxSLPips = 100;                           // Maximum SL (pips)

input group "=== Trade Batch Settings ==="
input int      MaxBatchesPerH1Signal = 2;                 // Max trade batches per H1 signal
input int      SignalTimeoutHours = 4;                    // Reset signal if no trade within X hours
input bool     ResetOnNewH1Bar = true;                    // Reset if new H1 bar and no trades taken
input bool     ResetOnOppositeSignal = true;              // Reset if opposite H1 engulfing detected

input group "=== Spread Limits (in Pips) ==="
input double   MaxSpread_GBPUSD = 4.0;                    // Max spread for GBPUSD (pips)
input double   MaxSpread_GBPJPY = 5.0;                    // Max spread for GBPJPY (pips)

input group "=== Trading Sessions ==="
input bool     EnableSessionFilter = false;               // Enable session filter (FALSE = 24/7)
input int      BrokerGMTOffset = 2;                       // Broker GMT offset

input group "=== Asian Session ==="
input bool     TradeAsianSession = false;                 // Trade during Asian session (PERMANENTLY BLOCKED)
input int      AsianStartHour = 0;                        // Asian session start (GMT)
input int      AsianEndHour = 7;                          // Asian session end (GMT) - ends when London starts

input group "=== London Session ==="
input bool     TradeLondonSession = true;                 // Trade during London session
input int      LondonStartHour = 7;                       // London session start (GMT)
input int      LondonEndHour = 16;                        // London session end (GMT)

input group "=== New York Session ==="
input bool     TradeNewYorkSession = true;                // Trade during New York session
input int      NewYorkStartHour = 13;                     // New York session start (GMT)
input int      NewYorkEndHour = 22;                       // New York session end (GMT)

input group "=== Daily Limits ==="
input int      MaxTradesPerDay = 0;                       // Max individual trades/day (0=unlimited, 2 per batch)
input double   MaxDailyLossPercent = 10.0;                // Max daily loss %
input double   DailyProfitTarget = 0;                     // Daily profit target $ (0 = disabled)

input group "=== Per-Symbol Trade Limits ==="
input int      MaxTradesPerDay_GBPUSD = 0;                // Max trades per day GBPUSD (0 = unlimited)
input int      MaxTradesPerDay_GBPJPY = 0;                // Max trades per day GBPJPY (0 = unlimited)

input group "=== Fibonacci Confirmation ==="
input bool     UseFibConfirmation = true;                 // Require fib retracement confirmation before entry
input double   FibMinRetracementPct = 38.2;               // Minimum retracement depth (%)
input int      FibLookbackBars = 250;                     // Max M5 bars to scan for prior full-EMA touch

input group "=== Notifications ==="
input int      AccountPingMinutes = 15;                   // Account heartbeat ping interval (minutes)

input group "=== Debug ==="
input bool     EnableLogs = true;                         // Enable debug logging
input bool     VerboseLogs = false;                       // Extra verbose logging
input int      TimerIntervalMs = 500;                     // Timer interval (ms)

//+------------------------------------------------------------------+
//| Constants and Enums                                              |
//+------------------------------------------------------------------+
#define MAX_SYMBOLS 2
#define TF_H1 0
#define TF_M5 1

enum TREND_STATE {
   TREND_NONE = 0,
   TREND_BULLISH = 1,
   TREND_BEARISH = -1
};

enum SIGNAL_STATE {
   STATE_WAITING_H1_SIGNAL = 0,
   STATE_WAITING_M5_RETEST = 1,
   STATE_WAITING_M5_ENGULFING = 2,
   STATE_BATCH1_ACTIVE = 3,
   STATE_WAITING_M5_RETEST2 = 4,
   STATE_BATCH2_ACTIVE = 5,
   STATE_SIGNAL_COMPLETE = 6
};

enum ENGULF_TYPE {
   ENGULF_NONE = 0,
   ENGULF_SINGLE_BULLISH = 1,
   ENGULF_SINGLE_BEARISH = 2,
   ENGULF_DOUBLE_BULLISH = 3,
   ENGULF_DOUBLE_BEARISH = 4
};

enum SYMBOL_TYPE {
   SYMBOL_TYPE_MAJOR = 0,
   SYMBOL_TYPE_JPY = 1
};

//+------------------------------------------------------------------+
//| Forex Symbol Calculator Class                                    |
//+------------------------------------------------------------------+
class CForexCalculator {
private:
   string      m_symbol;
   SYMBOL_TYPE m_type;
   int         m_digits;
   double      m_point;
   double      m_tickSize;
   double      m_tickValue;
   double      m_pipSize;
   double      m_pipValue;
   double      m_minLot;
   double      m_maxLot;
   double      m_lotStep;
   double      m_maxSpread;
   double      m_contractSize;

public:
   bool Init(string symbol, double maxSpreadPips) {
      m_symbol = symbol;
      m_maxSpread = maxSpreadPips;

      m_digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
      m_point = SymbolInfoDouble(symbol, SYMBOL_POINT);
      m_tickSize = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
      m_tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
      m_minLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
      m_maxLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
      m_lotStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
      m_contractSize = SymbolInfoDouble(symbol, SYMBOL_TRADE_CONTRACT_SIZE);

      if(m_tickSize <= 0) return false;

      string sym = symbol;
      StringToUpper(sym);

      // Determine symbol type and pip size
      if(StringFind(sym, "JPY") >= 0) {
         m_type = SYMBOL_TYPE_JPY;
         // JPY pairs: pip is 0.01 (2 decimal) or 0.001 (3 decimal for sub-pip brokers)
         m_pipSize = (m_digits == 3) ? 0.01 : 0.01;
      }
      else {
         m_type = SYMBOL_TYPE_MAJOR;
         // Major pairs: pip is 0.0001 (4 decimal) or 0.00001 (5 decimal for sub-pip brokers)
         m_pipSize = (m_digits == 5) ? 0.0001 : 0.0001;
      }

      m_pipValue = CalculatePipValueDynamic(1.0);
      if(m_pipValue <= 0) m_pipValue = GetFallbackPipValue(1.0);

      return (m_pipValue > 0);
   }

   double CalculatePipValueDynamic(double lots) {
      double bid = SymbolInfoDouble(m_symbol, SYMBOL_BID);
      if(bid <= 0) return GetFallbackPipValue(lots);

      // Method 1: OrderCalcProfit (most accurate)
      double profit = 0;
      if(OrderCalcProfit(ORDER_TYPE_BUY, m_symbol, lots, bid, bid + m_pipSize, profit)) {
         if(profit > 0) return profit;
      }

      // Method 2: Tick-based calculation
      if(m_tickSize > 0 && m_tickValue > 0) {
         double tickBasedValue = (m_pipSize / m_tickSize) * m_tickValue * lots;
         if(tickBasedValue > 0) return tickBasedValue;
      }

      return GetFallbackPipValue(lots);
   }

   double GetFallbackPipValue(double lots) {
      // Standard pip values for 1 lot:
      // GBPUSD: ~$10 per pip (varies with GBP/USD rate)
      // GBPJPY: ~$7 per pip (varies with USD/JPY rate)
      switch(m_type) {
         case SYMBOL_TYPE_JPY:   return 7.0 * lots;
         case SYMBOL_TYPE_MAJOR:
         default:                return 10.0 * lots;
      }
   }

   string      GetSymbol()       { return m_symbol; }
   SYMBOL_TYPE GetType()         { return m_type; }
   int         GetDigits()       { return m_digits; }
   double      GetPoint()        { return m_point; }
   double      GetPipSize()      { return m_pipSize; }
   double      GetPipValue()     { return m_pipValue; }
   double      GetMinLot()       { return m_minLot; }
   double      GetMaxLot()       { return m_maxLot; }
   double      GetLotStep()      { return m_lotStep; }
   double      GetMaxSpread()    { return m_maxSpread; }

   double GetPipValueForLots(double lots) {
      double dynamicValue = CalculatePipValueDynamic(lots);
      if(dynamicValue > 0) return dynamicValue;
      return m_pipValue * lots;
   }

   double ToPips(double priceDiff) {
      if(m_pipSize <= 0) return 0;
      return MathAbs(priceDiff) / m_pipSize;
   }

   double ToPrice(double pips) {
      return pips * m_pipSize;
   }

   double GetSpreadPips() {
      double ask = SymbolInfoDouble(m_symbol, SYMBOL_ASK);
      double bid = SymbolInfoDouble(m_symbol, SYMBOL_BID);
      return (ask - bid) / m_pipSize;
   }

   bool IsSpreadOK() {
      return GetSpreadPips() <= m_maxSpread;
   }

   double NormalizeLots(double lots) {
      if(m_lotStep <= 0) return m_minLot;
      lots = MathFloor(lots / m_lotStep) * m_lotStep;
      lots = MathMax(m_minLot, MathMin(m_maxLot, lots));
      return NormalizeDouble(lots, 2);
   }

   string GetTypeName() {
      switch(m_type) {
         case SYMBOL_TYPE_JPY:   return "JPY_PAIR";
         case SYMBOL_TYPE_MAJOR: return "MAJOR";
         default: return "UNKNOWN";
      }
   }
};

//+------------------------------------------------------------------+
//| Trade Tracking Structure                                         |
//+------------------------------------------------------------------+
struct TradeInfo {
   ulong    ticket;          // Order ticket (for display/logging)
   ulong    positionId;      // Position identifier (for history lookup)
   double   entryPrice;
   double   sl;
   double   tp;
   double   lots;
   double   rrRatio;
   bool     isOpen;
   bool     hitTP;
   bool     breakevenSet;    // Track if breakeven already applied (success)
   bool     bePending;       // BE requested but not yet confirmed - retry every tick
   int      bePendingTicks;  // Count of failed BE attempts while pending
   bool     notified;        // TP1+BE combined (or terminal) notification already sent
   bool     closeNotified;   // Trade-close broadcast already sent for this slot
   datetime openTime;
};

//+------------------------------------------------------------------+
//| Enhanced Statistics Structure                                    |
//+------------------------------------------------------------------+
struct SymbolStats {
   int      totalTrades;
   int      wins;
   int      losses;
   double   grossProfit;
   double   grossLoss;
   double   netProfit;
   double   largestWin;
   double   largestLoss;
   int      h1SignalsDetected;
   int      h1SignalsTraded;
   int      fibRejections;        // Entries rejected by fib confirmation
   int      batch1Trades;
   int      batch2Trades;
   int      trade1_1_TPHits;
   int      trade1_2_TPHits;
   int      consecutiveWins;
   int      consecutiveLosses;
   int      maxConsecutiveWins;
   int      maxConsecutiveLosses;

   double WinRate() {
      if(totalTrades == 0) return 0;
      return (double)wins / totalTrades * 100.0;
   }

   double ProfitFactor() {
      if(MathAbs(grossLoss) < 0.01) return grossProfit > 0 ? 999.99 : 0;
      return grossProfit / MathAbs(grossLoss);
   }

   double AvgWin() {
      if(wins == 0) return 0;
      return grossProfit / wins;
   }

   double AvgLoss() {
      if(losses == 0) return 0;
      return MathAbs(grossLoss) / losses;
   }

   double Expectancy() {
      if(totalTrades == 0) return 0;
      return netProfit / totalTrades;
   }

   double SignalConversionRate() {
      if(h1SignalsDetected == 0) return 0;
      return (double)h1SignalsTraded / h1SignalsDetected * 100.0;
   }

   double Trade1_1_HitRate() {
      int totalBatch1 = batch1Trades / 2;
      if(totalBatch1 == 0) return 0;
      return (double)trade1_1_TPHits / totalBatch1 * 100.0;
   }

   double Trade1_2_HitRate() {
      int totalBatch1 = batch1Trades / 2;
      if(totalBatch1 == 0) return 0;
      return (double)trade1_2_TPHits / totalBatch1 * 100.0;
   }
};

//+------------------------------------------------------------------+
//| Symbol Configuration Structure                                   |
//+------------------------------------------------------------------+
struct SymbolConfig {
   string            name;
   bool              enabled;
   CForexCalculator  calc;

   // Indicator handles [TF_H1, TF_M5]
   int               emaFastHandle[2];
   int               emaSlowHandle[2];
   int               atrHandle[2];

   // Signal State
   SIGNAL_STATE      signalState;
   TREND_STATE       h1Direction;
   datetime          h1SignalTime;
   double            h1SignalPrice;
   ENGULF_TYPE       h1EngulfType;

   // M5 Tracking
   bool              m5RetestDetected;
   datetime          m5RetestTime;
   bool              m5EngulfDetected;

   // Batch Tracking
   int               batchCount;
   TradeInfo         trade1_1;
   TradeInfo         trade1_2;
   TradeInfo         trade2_1;
   TradeInfo         trade2_2;

   // Statistics
   SymbolStats       stats;

   // Bar tracking
   datetime          lastBarTime[2];

   // Activity tracking
   datetime          lastH1BarCheck;
   datetime          lastM5BarCheck;
   int               h1BarsAnalyzed;
   int               m5BarsAnalyzed;
   string            lastH1Result;
   string            lastM5Result;

   // Per-symbol trade limits
   int               dailyTrades;        // Per-symbol daily trade counter
   int               maxTradesPerDay;    // Per-symbol max trades limit
};

//+------------------------------------------------------------------+
//| Global Variables                                                 |
//+------------------------------------------------------------------+
CTrade trade;
CPositionInfo position;
CAccountInfo account;

SymbolConfig g_symbols[MAX_SYMBOLS];
int g_activeSymbols = 0;
string g_symbolNames[MAX_SYMBOLS] = {"GBPUSD", "GBPJPY"};
bool g_symbolEnabled[MAX_SYMBOLS];
double g_maxSpreads[MAX_SYMBOLS];

// Global statistics
double g_maxDrawdown = 0;
double g_peakBalance = 0;
datetime g_testStartTime = 0;
datetime g_testEndTime = 0;
double g_initialBalance = 0;

// Daily tracking
int g_dailyTrades = 0;
datetime g_dailyResetTime = 0;
double g_dailyStartBalance = 0;
double g_dailyPnL = 0;
bool g_dailyLossLimitHit = false;
bool g_botEnabled = true;

// Server connection
datetime g_lastAccountPing = 0;   // Last account heartbeat ping (AccountPingMinutes)

// Tester
bool g_isTester = false;
bool g_isOptimization = false;

// Visual EMA handles (for chart display)
int g_emaFastVisual = INVALID_HANDLE;
int g_emaSlowVisual = INVALID_HANDLE;

//+------------------------------------------------------------------+
//| Logging Functions                                                |
//+------------------------------------------------------------------+
void Log(string msg, string cat = "INFO") {
   if(EnableLogs && !g_isOptimization)
      Print("[", cat, "] ", msg);
}

void LogVerbose(string msg, string cat = "DEBUG") {
   if(EnableLogs && VerboseLogs && !g_isOptimization)
      Print("[", cat, "] ", msg);
}

//+------------------------------------------------------------------+
//| Get Current GMT Hour                                             |
//+------------------------------------------------------------------+
int GetGMTHour() {
   datetime serverTime = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(serverTime, dt);

   int gmtHour = dt.hour - BrokerGMTOffset;
   if(gmtHour < 0) gmtHour += 24;
   if(gmtHour >= 24) gmtHour -= 24;

   return gmtHour;
}

//+------------------------------------------------------------------+
//| Check if Hour is in Session Range                                |
//+------------------------------------------------------------------+
bool IsHourInSession(int gmtHour, int startHour, int endHour) {
   if(startHour < endHour) {
      return (gmtHour >= startHour && gmtHour < endHour);
   }
   else {
      return (gmtHour >= startHour || gmtHour < endHour);
   }
}

//+------------------------------------------------------------------+
//| Check if Currently in Asian Session (ALWAYS BLOCKED)             |
//| Asian session: 0:00-7:00 GMT (1:00-8:00 WAT Nigerian time)       |
//+------------------------------------------------------------------+
bool IsAsianSession() {
   int gmtHour = GetGMTHour();
   return IsHourInSession(gmtHour, AsianStartHour, AsianEndHour);
}

//+------------------------------------------------------------------+
//| Check if Trading Allowed in Current Session                      |
//+------------------------------------------------------------------+
bool IsTradingAllowedInSession() {
   if(!EnableSessionFilter) return true;

   int gmtHour = GetGMTHour();

   if(TradeAsianSession && IsHourInSession(gmtHour, AsianStartHour, AsianEndHour)) return true;
   if(TradeLondonSession && IsHourInSession(gmtHour, LondonStartHour, LondonEndHour)) return true;
   if(TradeNewYorkSession && IsHourInSession(gmtHour, NewYorkStartHour, NewYorkEndHour)) return true;

   return false;
}

//+------------------------------------------------------------------+
//| Get State Name                                                   |
//+------------------------------------------------------------------+
string GetStateName(SIGNAL_STATE state) {
   switch(state) {
      case STATE_WAITING_H1_SIGNAL:    return "WAITING_H1_SIGNAL";
      case STATE_WAITING_M5_RETEST:    return "WAITING_M5_RETEST";
      case STATE_WAITING_M5_ENGULFING: return "WAITING_M5_ENGULFING";
      case STATE_BATCH1_ACTIVE:        return "BATCH1_ACTIVE";
      case STATE_WAITING_M5_RETEST2:   return "WAITING_M5_RETEST2";
      case STATE_BATCH2_ACTIVE:        return "BATCH2_ACTIVE";
      case STATE_SIGNAL_COMPLETE:      return "SIGNAL_COMPLETE";
      default: return "UNKNOWN";
   }
}

//+------------------------------------------------------------------+
//| Get Engulf Type Name                                             |
//+------------------------------------------------------------------+
string GetEngulfName(ENGULF_TYPE type) {
   switch(type) {
      case ENGULF_SINGLE_BULLISH: return "SINGLE_BULL_ENGULF";
      case ENGULF_SINGLE_BEARISH: return "SINGLE_BEAR_ENGULF";
      case ENGULF_DOUBLE_BULLISH: return "DOUBLE_BULL_ENGULF";
      case ENGULF_DOUBLE_BEARISH: return "DOUBLE_BEAR_ENGULF";
      default: return "NONE";
   }
}

//+------------------------------------------------------------------+
//| Calculate Risk Amount                                            |
//+------------------------------------------------------------------+
double GetRiskAmount() {
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount;

   if(UsePercentageRisk) {
      riskAmount = balance * RiskPercent / 100.0;
   } else {
      riskAmount = RiskDollars;
   }

   double minRisk = balance * MinRiskPercent / 100.0;
   double maxRisk = balance * MaxRiskPercent / 100.0;

   if(riskAmount < minRisk) riskAmount = minRisk;
   if(riskAmount > maxRisk) riskAmount = maxRisk;

   return riskAmount;
}

//+------------------------------------------------------------------+
//| Calculate Lot Size                                               |
//+------------------------------------------------------------------+
double CalculateLotSize(int symbolIndex, double slPips) {
   if(slPips <= 0) slPips = MinSLPips;

   double riskAmount = GetRiskAmount();
   double pipValuePerLot = g_symbols[symbolIndex].calc.GetPipValueForLots(1.0);

   if(pipValuePerLot <= 0) pipValuePerLot = g_symbols[symbolIndex].calc.GetFallbackPipValue(1.0);

   double rawLots = riskAmount / (slPips * pipValuePerLot);
   double lots = g_symbols[symbolIndex].calc.NormalizeLots(rawLots);

   Log(g_symbols[symbolIndex].name + " LOT: Risk=$" + DoubleToString(riskAmount, 2) +
       " / (" + DoubleToString(slPips, 1) + "p x $" + DoubleToString(pipValuePerLot, 2) +
       ") = " + DoubleToString(lots, 2) + " lots", "LOTS");

   return lots;
}

//+------------------------------------------------------------------+
//| Get EMA Values                                                   |
//+------------------------------------------------------------------+
bool GetEMAValues(int handle, double &values[], int count = 3) {
   ArraySetAsSeries(values, true);
   int copied = CopyBuffer(handle, 0, 0, count, values);
   return (copied >= count);
}

//+------------------------------------------------------------------+
//| Get ATR Value                                                    |
//+------------------------------------------------------------------+
double GetATR(int handle, int shift = 1) {
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(handle, 0, shift, 1, atr) <= 0) return 0;
   return atr[0];
}

//+------------------------------------------------------------------+
//| Get EMA Trend Direction                                          |
//| Returns TREND_BULLISH if EMA Fast > EMA Slow                     |
//| Returns TREND_BEARISH if EMA Fast < EMA Slow                     |
//| Returns TREND_NONE if unable to determine                        |
//+------------------------------------------------------------------+
TREND_STATE GetEMATrend(int fastHandle, int slowHandle, int barIndex = 0) {
   double emaFast[], emaSlow[];
   if(!GetEMAValues(fastHandle, emaFast, barIndex + 1)) return TREND_NONE;
   if(!GetEMAValues(slowHandle, emaSlow, barIndex + 1)) return TREND_NONE;

   if(emaFast[barIndex] > emaSlow[barIndex]) return TREND_BULLISH;
   if(emaFast[barIndex] < emaSlow[barIndex]) return TREND_BEARISH;
   return TREND_NONE;
}

//+------------------------------------------------------------------+
//| Get Trend Name String                                            |
//+------------------------------------------------------------------+
string GetTrendName(TREND_STATE trend) {
   switch(trend) {
      case TREND_BULLISH: return "BULLISH";
      case TREND_BEARISH: return "BEARISH";
      default: return "NONE";
   }
}

//+------------------------------------------------------------------+
//| Check for New Bar                                                |
//+------------------------------------------------------------------+
bool IsNewBar(int symbolIndex, int tfIndex) {
   ENUM_TIMEFRAMES tf = (tfIndex == TF_H1) ? HTF_TIMEFRAME : LTF_TIMEFRAME;
   datetime currentBarTime = iTime(g_symbols[symbolIndex].name, tf, 0);

   if(currentBarTime == 0) return false;

   if(currentBarTime != g_symbols[symbolIndex].lastBarTime[tfIndex]) {
      g_symbols[symbolIndex].lastBarTime[tfIndex] = currentBarTime;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Detect Single Candle Engulfing                                   |
//+------------------------------------------------------------------+
ENGULF_TYPE DetectSingleEngulfing(string symbol, ENUM_TIMEFRAMES tf, int barIndex = 1) {
   double O1 = iOpen(symbol, tf, barIndex);
   double C1 = iClose(symbol, tf, barIndex);
   double H1 = iHigh(symbol, tf, barIndex);
   double L1 = iLow(symbol, tf, barIndex);
   double O2 = iOpen(symbol, tf, barIndex + 1);
   double C2 = iClose(symbol, tf, barIndex + 1);

   double body1 = MathAbs(C1 - O1);
   double body2 = MathAbs(C2 - O2);
   double range1 = H1 - L1;

   if(range1 == 0 || body1 == 0) return ENGULF_NONE;

   bool prevBearish = (C2 < O2);
   bool currBullish = (C1 > O1);
   bool bullEngulfs = (C1 >= O2) && (O1 <= C2) && (body1 > body2);

   if(prevBearish && currBullish && bullEngulfs) {
      return ENGULF_SINGLE_BULLISH;
   }

   bool prevBullish = (C2 > O2);
   bool currBearish = (C1 < O1);
   bool bearEngulfs = (O1 >= C2) && (C1 <= O2) && (body1 > body2);

   if(prevBullish && currBearish && bearEngulfs) {
      return ENGULF_SINGLE_BEARISH;
   }

   return ENGULF_NONE;
}

//+------------------------------------------------------------------+
//| Detect Double Candle Engulfing                                   |
//+------------------------------------------------------------------+
ENGULF_TYPE DetectDoubleEngulfing(string symbol, ENUM_TIMEFRAMES tf, int barIndex = 1) {
   double O1 = iOpen(symbol, tf, barIndex);
   double C1 = iClose(symbol, tf, barIndex);
   double O2 = iOpen(symbol, tf, barIndex + 1);
   double C2 = iClose(symbol, tf, barIndex + 1);
   double O3 = iOpen(symbol, tf, barIndex + 2);
   double C3 = iClose(symbol, tf, barIndex + 2);

   bool candle1Bullish = (C1 > O1);
   bool candle2Bullish = (C2 > O2);
   bool candle1Bearish = (C1 < O1);
   bool candle2Bearish = (C2 < O2);

   double combinedHigh = MathMax(MathMax(C1, O1), MathMax(C2, O2));
   double combinedLow = MathMin(MathMin(C1, O1), MathMin(C2, O2));

   double prevBodyHigh = MathMax(C3, O3);
   double prevBodyLow = MathMin(C3, O3);

   bool prevBearish = (C3 < O3);
   bool bothBullish = candle1Bullish && candle2Bullish;
   bool bullEngulfs = (combinedHigh >= prevBodyHigh) && (combinedLow <= prevBodyLow);

   if(prevBearish && bothBullish && bullEngulfs) {
      return ENGULF_DOUBLE_BULLISH;
   }

   bool prevBullish = (C3 > O3);
   bool bothBearish = candle1Bearish && candle2Bearish;
   bool bearEngulfs = (combinedHigh >= prevBodyHigh) && (combinedLow <= prevBodyLow);

   if(prevBullish && bothBearish && bearEngulfs) {
      return ENGULF_DOUBLE_BEARISH;
   }

   return ENGULF_NONE;
}

//+------------------------------------------------------------------+
//| Detect Any Engulfing Pattern                                     |
//+------------------------------------------------------------------+
ENGULF_TYPE DetectEngulfing(string symbol, ENUM_TIMEFRAMES tf, int barIndex = 1) {
   ENGULF_TYPE single = DetectSingleEngulfing(symbol, tf, barIndex);
   if(single != ENGULF_NONE) return single;

   ENGULF_TYPE dbl = DetectDoubleEngulfing(symbol, tf, barIndex);
   return dbl;
}

//+------------------------------------------------------------------+
//| Check if Candle Closed Above/Below EMA Lines                     |
//+------------------------------------------------------------------+
bool CheckEngulfingAboveBelowEMA(int symbolIndex, ENGULF_TYPE engulfType, int barIndex = 1) {
   string symbol = g_symbols[symbolIndex].name;

   double emaFast[], emaSlow[];
   if(!GetEMAValues(g_symbols[symbolIndex].emaFastHandle[TF_H1], emaFast, barIndex + 1)) return false;
   if(!GetEMAValues(g_symbols[symbolIndex].emaSlowHandle[TF_H1], emaSlow, barIndex + 1)) return false;

   double close = iClose(symbol, HTF_TIMEFRAME, barIndex);
   double emaUpper = MathMax(emaFast[barIndex], emaSlow[barIndex]);
   double emaLower = MathMin(emaFast[barIndex], emaSlow[barIndex]);

   if(engulfType == ENGULF_SINGLE_BULLISH || engulfType == ENGULF_DOUBLE_BULLISH) {
      return (close > emaUpper);
   }

   if(engulfType == ENGULF_SINGLE_BEARISH || engulfType == ENGULF_DOUBLE_BEARISH) {
      return (close < emaLower);
   }

   return false;
}

//+------------------------------------------------------------------+
//| Check if Price is in EMA Zone                                    |
//+------------------------------------------------------------------+
bool IsPriceInEMAZone(int symbolIndex, int tfIndex, int barIndex = 1) {
   string symbol = g_symbols[symbolIndex].name;
   ENUM_TIMEFRAMES tf = (tfIndex == TF_H1) ? HTF_TIMEFRAME : LTF_TIMEFRAME;
   int fastHandle = g_symbols[symbolIndex].emaFastHandle[tfIndex];
   int slowHandle = g_symbols[symbolIndex].emaSlowHandle[tfIndex];

   double emaFast[], emaSlow[];
   if(!GetEMAValues(fastHandle, emaFast, barIndex + 1)) return false;
   if(!GetEMAValues(slowHandle, emaSlow, barIndex + 1)) return false;

   double low = iLow(symbol, tf, barIndex);
   double high = iHigh(symbol, tf, barIndex);

   double emaUpper = MathMax(emaFast[barIndex], emaSlow[barIndex]);
   double emaLower = MathMin(emaFast[barIndex], emaSlow[barIndex]);

   bool touchesZone = (low <= emaUpper && high >= emaLower);

   return touchesZone;
}

//+------------------------------------------------------------------+
//| Find Chart by Symbol                                              |
//+------------------------------------------------------------------+
long FindChartBySymbol(string symbol) {
   long chartId = ChartFirst();
   while(chartId != -1) {
      if(ChartSymbol(chartId) == symbol) {
         return chartId;
      }
      chartId = ChartNext(chartId);
   }
   return -1;
}

//+------------------------------------------------------------------+
//| Add Visual EMA Indicators to All Symbol Charts                    |
//+------------------------------------------------------------------+
void AddVisualEMAs() {
   // Add EMAs to the main chart (the one EA is attached to)
   long mainChartId = ChartID();
   ENUM_TIMEFRAMES tf = (ENUM_TIMEFRAMES)Period();
   string chartSymbol = Symbol();

   g_emaFastVisual = iMA(chartSymbol, tf, EMA_FAST_PERIOD, 0, MODE_EMA, EMA_APPLIED_PRICE);
   if(g_emaFastVisual != INVALID_HANDLE) {
      ChartIndicatorAdd(mainChartId, 0, g_emaFastVisual);
   }

   g_emaSlowVisual = iMA(chartSymbol, tf, EMA_SLOW_PERIOD, 0, MODE_EMA, EMA_APPLIED_PRICE);
   if(g_emaSlowVisual != INVALID_HANDLE) {
      ChartIndicatorAdd(mainChartId, 0, g_emaSlowVisual);
   }

   Log("Visual EMAs added to main chart: EMA " + IntegerToString(EMA_FAST_PERIOD) + " & EMA " + IntegerToString(EMA_SLOW_PERIOD), "INIT");

   // Add EMAs to each enabled symbol's chart
   for(int i = 0; i < MAX_SYMBOLS; i++) {
      if(!g_symbols[i].enabled) continue;

      string symbol = g_symbols[i].name;
      long chartId = FindChartBySymbol(symbol);

      if(chartId != -1 && chartId != mainChartId) {
         // Get the timeframe of that chart
         ENUM_TIMEFRAMES symbolTf = ChartPeriod(chartId);

         // Create visual EMAs for that symbol and chart
         int fastHandle = iMA(symbol, symbolTf, EMA_FAST_PERIOD, 0, MODE_EMA, EMA_APPLIED_PRICE);
         int slowHandle = iMA(symbol, symbolTf, EMA_SLOW_PERIOD, 0, MODE_EMA, EMA_APPLIED_PRICE);

         if(fastHandle != INVALID_HANDLE) {
            ChartIndicatorAdd(chartId, 0, fastHandle);
         }
         if(slowHandle != INVALID_HANDLE) {
            ChartIndicatorAdd(chartId, 0, slowHandle);
         }

         Log("Visual EMAs added to " + symbol + " chart", "INIT");
      }
   }
}

//+------------------------------------------------------------------+
//| Remove Visual EMA Indicators from Chart                          |
//+------------------------------------------------------------------+
void RemoveVisualEMAs() {
   long chartId = ChartID();
   int total = ChartIndicatorsTotal(chartId, 0);

   // Remove any MA indicators we added
   for(int i = total - 1; i >= 0; i--) {
      string name = ChartIndicatorName(chartId, 0, i);
      if(StringFind(name, "MA(") >= 0) {
         ChartIndicatorDelete(chartId, 0, name);
      }
   }

   // Release handles
   if(g_emaFastVisual != INVALID_HANDLE) {
      IndicatorRelease(g_emaFastVisual);
      g_emaFastVisual = INVALID_HANDLE;
   }
   if(g_emaSlowVisual != INVALID_HANDLE) {
      IndicatorRelease(g_emaSlowVisual);
      g_emaSlowVisual = INVALID_HANDLE;
   }
}

//+------------------------------------------------------------------+
//| Initialize Symbol Configuration                                  |
//+------------------------------------------------------------------+
bool InitSymbolConfig(int index, string symbolName, bool enabled, double maxSpread) {
   g_symbols[index].name = "";
   g_symbols[index].enabled = false;

   if(!enabled) return true;

   string actualSymbol = symbolName;
   if(!SymbolSelect(symbolName, true)) {
      string suffixes[] = {"", ".s", ".pro", ".ecn", ".raw", "m", ".", "#", "-", "_"};
      bool found = false;

      for(int i = 0; i < ArraySize(suffixes); i++) {
         string testSymbol = symbolName + suffixes[i];
         if(SymbolSelect(testSymbol, true)) {
            actualSymbol = testSymbol;
            found = true;
            break;
         }
      }

      if(!found) {
         Log("Symbol " + symbolName + " not available", "WARN");
         return true;
      }
   }

   if(!g_symbols[index].calc.Init(actualSymbol, maxSpread)) {
      Log("Failed to initialize calculator for " + actualSymbol, "ERROR");
      return false;
   }

   g_symbols[index].name = actualSymbol;
   g_symbols[index].enabled = true;

   // Create indicator handles
   g_symbols[index].emaFastHandle[TF_H1] = iMA(actualSymbol, HTF_TIMEFRAME, EMA_FAST_PERIOD, 0, MODE_EMA, EMA_APPLIED_PRICE);
   g_symbols[index].emaSlowHandle[TF_H1] = iMA(actualSymbol, HTF_TIMEFRAME, EMA_SLOW_PERIOD, 0, MODE_EMA, EMA_APPLIED_PRICE);
   g_symbols[index].atrHandle[TF_H1] = iATR(actualSymbol, HTF_TIMEFRAME, ATR_Period);

   g_symbols[index].emaFastHandle[TF_M5] = iMA(actualSymbol, LTF_TIMEFRAME, EMA_FAST_PERIOD, 0, MODE_EMA, EMA_APPLIED_PRICE);
   g_symbols[index].emaSlowHandle[TF_M5] = iMA(actualSymbol, LTF_TIMEFRAME, EMA_SLOW_PERIOD, 0, MODE_EMA, EMA_APPLIED_PRICE);
   g_symbols[index].atrHandle[TF_M5] = iATR(actualSymbol, LTF_TIMEFRAME, ATR_Period);

   if(g_symbols[index].emaFastHandle[TF_H1] == INVALID_HANDLE ||
      g_symbols[index].emaSlowHandle[TF_H1] == INVALID_HANDLE ||
      g_symbols[index].emaFastHandle[TF_M5] == INVALID_HANDLE ||
      g_symbols[index].emaSlowHandle[TF_M5] == INVALID_HANDLE ||
      g_symbols[index].atrHandle[TF_M5] == INVALID_HANDLE) {
      Log("Failed to create indicators for " + actualSymbol, "ERROR");
      g_symbols[index].enabled = false;
      return false;
   }

   ResetSymbolState(index);

   // Set per-symbol trade limits
   if(StringFind(actualSymbol, "GBPUSD") >= 0) {
      g_symbols[index].maxTradesPerDay = MaxTradesPerDay_GBPUSD;
   } else if(StringFind(actualSymbol, "GBPJPY") >= 0) {
      g_symbols[index].maxTradesPerDay = MaxTradesPerDay_GBPJPY;
   } else {
      g_symbols[index].maxTradesPerDay = 0; // Default unlimited
   }
   g_symbols[index].dailyTrades = 0;

   g_activeSymbols++;

   // Log pip value for verification
   double testPipValue = g_symbols[index].calc.GetPipValueForLots(1.0);
   Log("Initialized " + actualSymbol +
       " | Type: " + g_symbols[index].calc.GetTypeName() +
       " | PipSize: " + DoubleToString(g_symbols[index].calc.GetPipSize(), 5) +
       " | PipValue: $" + DoubleToString(testPipValue, 2) + "/lot", "INIT");

   return true;
}

//+------------------------------------------------------------------+
//| Restart-Safe State Persistence (MQL5 GlobalVariables)             |
//| Prefix: "FEB_" + symbol. Persists per-symbol state + per-trade    |
//| flags so a restart resumes monitoring without double-notifying.   |
//+------------------------------------------------------------------+
string PersistKey(int symbolIndex, string suffix) {
   return "FEB_" + g_symbols[symbolIndex].name + "_" + suffix;
}

void PersistTradeSlot(int symbolIndex, string slot, const TradeInfo &t) {
   GlobalVariableSet(PersistKey(symbolIndex, slot + "_tk"),    (double)t.ticket);
   GlobalVariableSet(PersistKey(symbolIndex, slot + "_pid"),   (double)t.positionId);
   GlobalVariableSet(PersistKey(symbolIndex, slot + "_entry"), t.entryPrice);
   GlobalVariableSet(PersistKey(symbolIndex, slot + "_sl"),    t.sl);
   GlobalVariableSet(PersistKey(symbolIndex, slot + "_tp"),    t.tp);
   GlobalVariableSet(PersistKey(symbolIndex, slot + "_lots"),  t.lots);
   GlobalVariableSet(PersistKey(symbolIndex, slot + "_rr"),    t.rrRatio);
   GlobalVariableSet(PersistKey(symbolIndex, slot + "_open"),  t.isOpen ? 1.0 : 0.0);
   GlobalVariableSet(PersistKey(symbolIndex, slot + "_hittp"), t.hitTP ? 1.0 : 0.0);
   GlobalVariableSet(PersistKey(symbolIndex, slot + "_be"),    t.breakevenSet ? 1.0 : 0.0);
   GlobalVariableSet(PersistKey(symbolIndex, slot + "_notif"), t.notified ? 1.0 : 0.0);
   GlobalVariableSet(PersistKey(symbolIndex, slot + "_cnotif"),t.closeNotified ? 1.0 : 0.0);
   GlobalVariableSet(PersistKey(symbolIndex, slot + "_otime"), (double)t.openTime);
}

void LoadTradeSlot(int symbolIndex, string slot, TradeInfo &t) {
   t.ticket       = (ulong)GlobalVariableGet(PersistKey(symbolIndex, slot + "_tk"));
   t.positionId   = (ulong)GlobalVariableGet(PersistKey(symbolIndex, slot + "_pid"));
   t.entryPrice   = GlobalVariableGet(PersistKey(symbolIndex, slot + "_entry"));
   t.sl           = GlobalVariableGet(PersistKey(symbolIndex, slot + "_sl"));
   t.tp           = GlobalVariableGet(PersistKey(symbolIndex, slot + "_tp"));
   t.lots         = GlobalVariableGet(PersistKey(symbolIndex, slot + "_lots"));
   t.rrRatio      = GlobalVariableGet(PersistKey(symbolIndex, slot + "_rr"));
   t.isOpen       = (GlobalVariableGet(PersistKey(symbolIndex, slot + "_open")) > 0.5);
   t.hitTP        = (GlobalVariableGet(PersistKey(symbolIndex, slot + "_hittp")) > 0.5);
   t.breakevenSet = (GlobalVariableGet(PersistKey(symbolIndex, slot + "_be")) > 0.5);
   t.notified     = (GlobalVariableGet(PersistKey(symbolIndex, slot + "_notif")) > 0.5);
   t.closeNotified= (GlobalVariableGet(PersistKey(symbolIndex, slot + "_cnotif")) > 0.5);
   t.bePending    = false;       // never persist a pending retry; re-derive on monitor
   t.bePendingTicks = 0;
   t.openTime     = (datetime)(long)GlobalVariableGet(PersistKey(symbolIndex, slot + "_otime"));
}

void PersistState(int symbolIndex) {
   if(g_isOptimization || g_isTester) return;
   GlobalVariableSet(PersistKey(symbolIndex, "state"),  (double)g_symbols[symbolIndex].signalState);
   GlobalVariableSet(PersistKey(symbolIndex, "batch"),  (double)g_symbols[symbolIndex].batchCount);
   GlobalVariableSet(PersistKey(symbolIndex, "dir"),    (double)g_symbols[symbolIndex].h1Direction);
   GlobalVariableSet(PersistKey(symbolIndex, "engulf"), (double)g_symbols[symbolIndex].h1EngulfType);
   GlobalVariableSet(PersistKey(symbolIndex, "h1time"), (double)g_symbols[symbolIndex].h1SignalTime);
   PersistTradeSlot(symbolIndex, "t11", g_symbols[symbolIndex].trade1_1);
   PersistTradeSlot(symbolIndex, "t12", g_symbols[symbolIndex].trade1_2);
   PersistTradeSlot(symbolIndex, "t21", g_symbols[symbolIndex].trade2_1);
   PersistTradeSlot(symbolIndex, "t22", g_symbols[symbolIndex].trade2_2);
}

void ClearPersistedState(int symbolIndex) {
   string prefix = "FEB_" + g_symbols[symbolIndex].name + "_";
   for(int i = GlobalVariablesTotal() - 1; i >= 0; i--) {
      string name = GlobalVariableName(i);
      if(StringFind(name, prefix) == 0) {
         GlobalVariableDel(name);
      }
   }
}

bool HasPersistedState(int symbolIndex) {
   return GlobalVariableCheck(PersistKey(symbolIndex, "state"));
}

//+------------------------------------------------------------------+
//| Reset Symbol State                                               |
//+------------------------------------------------------------------+
void ResetSymbolState(int symbolIndex) {
   g_symbols[symbolIndex].signalState = STATE_WAITING_H1_SIGNAL;
   g_symbols[symbolIndex].h1Direction = TREND_NONE;
   g_symbols[symbolIndex].h1SignalTime = 0;
   g_symbols[symbolIndex].h1SignalPrice = 0;
   g_symbols[symbolIndex].h1EngulfType = ENGULF_NONE;
   g_symbols[symbolIndex].m5RetestDetected = false;
   g_symbols[symbolIndex].m5RetestTime = 0;
   g_symbols[symbolIndex].m5EngulfDetected = false;
   g_symbols[symbolIndex].batchCount = 0;

   ZeroMemory(g_symbols[symbolIndex].trade1_1);
   ZeroMemory(g_symbols[symbolIndex].trade1_2);
   ZeroMemory(g_symbols[symbolIndex].trade2_1);
   ZeroMemory(g_symbols[symbolIndex].trade2_2);

   // Initialize activity tracking (keep counters, reset results)
   g_symbols[symbolIndex].lastH1Result = "Waiting...";
   g_symbols[symbolIndex].lastM5Result = "Waiting...";

   // Signal completed -> clear persisted tracking so a restart starts fresh
   ClearPersistedState(symbolIndex);

   Log(g_symbols[symbolIndex].name + " State machine RESET -> WAITING_H1_SIGNAL", "STATE");
}

//+------------------------------------------------------------------+
//| Check H1 for Engulfing Signal                                    |
//+------------------------------------------------------------------+
void CheckH1Signal(int symbolIndex) {
   string symbol = g_symbols[symbolIndex].name;

   if(!IsNewBar(symbolIndex, TF_H1)) return;

   // Track activity - NEW H1 BAR DETECTED
   g_symbols[symbolIndex].lastH1BarCheck = TimeCurrent();
   g_symbols[symbolIndex].h1BarsAnalyzed++;

   if(g_symbols[symbolIndex].signalState != STATE_WAITING_H1_SIGNAL) {
      g_symbols[symbolIndex].lastH1Result = "State: " + GetStateName(g_symbols[symbolIndex].signalState);
      Log("[" + symbol + " H1 BAR #" + IntegerToString(g_symbols[symbolIndex].h1BarsAnalyzed) + "] Skipped - Already have signal", "H1_CHECK");
      return;
   }

   ENGULF_TYPE engulf = DetectEngulfing(symbol, HTF_TIMEFRAME, 1);

   if(engulf == ENGULF_NONE) {
      g_symbols[symbolIndex].lastH1Result = "No engulfing pattern";
      Log("[" + symbol + " H1 BAR #" + IntegerToString(g_symbols[symbolIndex].h1BarsAnalyzed) + "] Checked - No engulfing pattern", "H1_CHECK");
      return;
   }

   // NEW: Check H1 EMA trend direction (EMA 10 vs EMA 23)
   TREND_STATE h1EmaTrend = GetEMATrend(g_symbols[symbolIndex].emaFastHandle[TF_H1], g_symbols[symbolIndex].emaSlowHandle[TF_H1], 1);

   if(h1EmaTrend == TREND_NONE) {
      g_symbols[symbolIndex].lastH1Result = GetEngulfName(engulf) + " - EMA trend unclear";
      Log("[" + symbol + " H1 BAR #" + IntegerToString(g_symbols[symbolIndex].h1BarsAnalyzed) + "] Found " + GetEngulfName(engulf) + " but EMA trend unclear - Skipping", "H1_CHECK");
      return;
   }

   // NEW: Validate engulfing matches EMA trend direction
   // Bullish trend = only accept bullish engulfing
   // Bearish trend = only accept bearish engulfing
   bool engulfMatchesTrend = false;
   if(h1EmaTrend == TREND_BULLISH && (engulf == ENGULF_SINGLE_BULLISH || engulf == ENGULF_DOUBLE_BULLISH)) {
      engulfMatchesTrend = true;
   } else if(h1EmaTrend == TREND_BEARISH && (engulf == ENGULF_SINGLE_BEARISH || engulf == ENGULF_DOUBLE_BEARISH)) {
      engulfMatchesTrend = true;
   }

   if(!engulfMatchesTrend) {
      g_symbols[symbolIndex].lastH1Result = GetEngulfName(engulf) + " - Against EMA trend (" + GetTrendName(h1EmaTrend) + ")";
      Log("[" + symbol + " H1 BAR #" + IntegerToString(g_symbols[symbolIndex].h1BarsAnalyzed) + "] Found " + GetEngulfName(engulf) +
          " but EMA trend is " + GetTrendName(h1EmaTrend) + " - Skipping (wrong direction)", "H1_CHECK");
      return;
   }

   Log("[" + symbol + " H1 BAR #" + IntegerToString(g_symbols[symbolIndex].h1BarsAnalyzed) + "] " + GetEngulfName(engulf) +
       " matches EMA trend (" + GetTrendName(h1EmaTrend) + ") - Checking EMA position", "H1_CHECK");

   // Found engulfing matching EMA trend, check EMA position
   if(!CheckEngulfingAboveBelowEMA(symbolIndex, engulf, 1)) {
      if(!IsPriceInEMAZone(symbolIndex, TF_H1, 1)) {
         g_symbols[symbolIndex].lastH1Result = GetEngulfName(engulf) + " - Not at EMA";
         Log("[" + symbol + " H1 BAR #" + IntegerToString(g_symbols[symbolIndex].h1BarsAnalyzed) + "] Found " + GetEngulfName(engulf) + " but NOT at EMA zone", "H1_CHECK");
         return;
      }
   }

   g_symbols[symbolIndex].h1EngulfType = engulf;
   g_symbols[symbolIndex].h1SignalTime = iTime(symbol, HTF_TIMEFRAME, 1);
   g_symbols[symbolIndex].h1SignalPrice = iClose(symbol, HTF_TIMEFRAME, 1);

   if(engulf == ENGULF_SINGLE_BULLISH || engulf == ENGULF_DOUBLE_BULLISH) {
      g_symbols[symbolIndex].h1Direction = TREND_BULLISH;
   } else {
      g_symbols[symbolIndex].h1Direction = TREND_BEARISH;
   }

   g_symbols[symbolIndex].signalState = STATE_WAITING_M5_RETEST;
   g_symbols[symbolIndex].m5RetestDetected = false;
   g_symbols[symbolIndex].m5EngulfDetected = false;

   g_symbols[symbolIndex].stats.h1SignalsDetected++;

   // Activity tracking - SIGNAL FOUND
   g_symbols[symbolIndex].lastH1Result = ">>> " + (g_symbols[symbolIndex].h1Direction == TREND_BULLISH ? "BUY" : "SELL") + " SIGNAL <<<";

   Log("========================================", "H1_SIGNAL");
   Log("[" + symbol + " H1 BAR #" + IntegerToString(g_symbols[symbolIndex].h1BarsAnalyzed) + "] >>> H1 SIGNAL DETECTED <<<", "H1_SIGNAL");
   Log("Type: " + GetEngulfName(engulf), "H1_SIGNAL");
   Log("Direction: " + (g_symbols[symbolIndex].h1Direction == TREND_BULLISH ? "BULLISH" : "BEARISH"), "H1_SIGNAL");
   Log("========================================", "H1_SIGNAL");
}

//+------------------------------------------------------------------+
//| Check M5 for Retest                                              |
//+------------------------------------------------------------------+
void CheckM5Retest(int symbolIndex) {
   string symbol = g_symbols[symbolIndex].name;

   // Track M5 activity on every new M5 bar
   static datetime lastM5Bar[MAX_SYMBOLS];
   datetime currentM5Bar = iTime(symbol, LTF_TIMEFRAME, 0);

   if(currentM5Bar != lastM5Bar[symbolIndex]) {
      lastM5Bar[symbolIndex] = currentM5Bar;
      g_symbols[symbolIndex].lastM5BarCheck = TimeCurrent();
      g_symbols[symbolIndex].m5BarsAnalyzed++;

      // FIRST: Check M5 EMA alignment IMMEDIATELY on each new M5 bar
      TREND_STATE m5EmaTrend = GetEMATrend(g_symbols[symbolIndex].emaFastHandle[TF_M5], g_symbols[symbolIndex].emaSlowHandle[TF_M5], 0);

      // If M5 EMA doesn't align with H1 trend, invalidate entire signal immediately
      if(m5EmaTrend != g_symbols[symbolIndex].h1Direction) {
         g_symbols[symbolIndex].lastM5Result = "M5 EMA mismatch (" + GetTrendName(m5EmaTrend) + " vs H1 " + GetTrendName(g_symbols[symbolIndex].h1Direction) + ") - INVALIDATED";
         Log("[" + symbol + " M5 BAR #" + IntegerToString(g_symbols[symbolIndex].m5BarsAnalyzed) + "] M5 EMA (" +
             GetTrendName(m5EmaTrend) + ") doesn't match H1 (" + GetTrendName(g_symbols[symbolIndex].h1Direction) + ") - SIGNAL INVALIDATED", "M5_CHECK");
         Log("Resetting state - waiting for new H1 signal...", "M5_CHECK");
         ResetSymbolState(symbolIndex);
         return;
      }

      // M5 EMA aligned - log and continue to check for retest
      g_symbols[symbolIndex].lastM5Result = "EMA aligned (" + GetTrendName(m5EmaTrend) + ") - Waiting for retest...";
      Log("[" + symbol + " M5 BAR #" + IntegerToString(g_symbols[symbolIndex].m5BarsAnalyzed) + "] M5 EMA aligned (" + GetTrendName(m5EmaTrend) + ") - Checking for EMA zone retest", "M5_CHECK");
   }

   // Only check for retest AFTER confirming M5 EMA alignment
   if(IsPriceInEMAZone(symbolIndex, TF_M5, 0)) {
      if(!g_symbols[symbolIndex].m5RetestDetected) {
         g_symbols[symbolIndex].m5RetestDetected = true;
         g_symbols[symbolIndex].m5RetestTime = iTime(symbol, LTF_TIMEFRAME, 0);   // bar open time (exact anchor for fib retest bar)
         g_symbols[symbolIndex].signalState = STATE_WAITING_M5_ENGULFING;

         // Activity tracking - RETEST FOUND
         g_symbols[symbolIndex].lastM5Result = ">>> RETEST DETECTED <<<";

         Log("[" + symbol + " M5 BAR #" + IntegerToString(g_symbols[symbolIndex].m5BarsAnalyzed) + "] >>> M5 RETEST DETECTED <<<", "M5_RETEST");
         Log("Now waiting for M5 engulfing confirmation...", "M5_RETEST");
      }
   }
}

//+------------------------------------------------------------------+
//| Fibonacci Retracement Confirmation (M5 only)                     |
//| Validates that the pullback into the current retest retraced     |
//| at least FibMinRetracementPct (and at most 100%) of the impulse  |
//| leg. The leg is measured from the last prior M5 candle that      |
//| touched BOTH EMAs (Touch A) to the extreme reached between       |
//| Touch A and the current retest (fib 0%).                         |
//| After first reaching the minimum level, price must NOT have      |
//| returned to the 0% level. Returns true if entry is allowed.      |
//| reason = human-readable detail for logging/status.               |
//+------------------------------------------------------------------+
bool CheckFibConfirmation(string symbol, int emaFastM5Handle, int emaSlowM5Handle,
                          int direction, datetime retestTime, string &reason) {
   reason = "";

   // Clamp lookback to available history
   int lookback = FibLookbackBars;
   if(lookback < 30) lookback = 30;
   int barsAvail = Bars(symbol, LTF_TIMEFRAME);
   if(barsAvail < lookback + 2) lookback = barsAvail - 2;
   if(lookback < 30) {
      reason = "insufficient M5 history (" + IntegerToString(barsAvail) + " bars)";
      return false;
   }

   // Copy EMA and price history once (series-indexed: 0 = newest)
   double emaFast[], emaSlow[], hi[], lo[];
   ArraySetAsSeries(emaFast, true);
   ArraySetAsSeries(emaSlow, true);
   ArraySetAsSeries(hi, true);
   ArraySetAsSeries(lo, true);
   if(CopyBuffer(emaFastM5Handle, 0, 0, lookback, emaFast) < lookback) { reason = "EMA fast copy failed"; return false; }
   if(CopyBuffer(emaSlowM5Handle, 0, 0, lookback, emaSlow) < lookback) { reason = "EMA slow copy failed"; return false; }
   if(CopyHigh(symbol, LTF_TIMEFRAME, 0, lookback, hi) < lookback) { reason = "high copy failed"; return false; }
   if(CopyLow(symbol, LTF_TIMEFRAME, 0, lookback, lo) < lookback) { reason = "low copy failed"; return false; }

   // Anchor Touch B at the recorded retest bar (engulfing bar may already be out of the zone)
   int retestBar = iBarShift(symbol, LTF_TIMEFRAME, retestTime);
   if(retestBar < 1) retestBar = 1;
   if(retestBar > lookback - 3) {
      reason = "retest bar outside lookback";
      return false;
   }

   // Expand the contiguous in-zone cluster at Touch B toward older bars
   int b = retestBar;
   while(b < lookback - 1) {
      double zUp = MathMax(emaFast[b], emaSlow[b]);
      double zDn = MathMin(emaFast[b], emaSlow[b]);
      bool inZone = (lo[b] <= zUp && hi[b] >= zDn);
      if(!inZone) break;
      b++;
   }
   int clusterBStart = b;   // first bar (older side) where price was out of the zone
   if(clusterBStart >= lookback - 2) {
      reason = "no impulse leg before retest";
      return false;
   }

   // Find Touch A: most recent PRIOR full-EMA-touch candle after price left the zone
   int aEnd = -1;
   bool leftZone = false;
   for(int i = clusterBStart; i < lookback - 1; i++) {
      double zUp = MathMax(emaFast[i], emaSlow[i]);
      double zDn = MathMin(emaFast[i], emaSlow[i]);
      bool inZone = (lo[i] <= zUp && hi[i] >= zDn);
      bool fullTouch = (lo[i] <= zDn && hi[i] >= zUp);
      if(!inZone) { leftZone = true; continue; }
      if(fullTouch && leftZone) { aEnd = i; break; }
   }
   if(aEnd < 0) {
      reason = "no prior full-EMA touch within " + IntegerToString(lookback) + " bars";
      return false;
   }

   // Expand Touch A cluster (contiguous full touches, older direction)
   int aStart = aEnd;
   while(aStart < lookback - 1) {
      double zUp = MathMax(emaFast[aStart + 1], emaSlow[aStart + 1]);
      double zDn = MathMin(emaFast[aStart + 1], emaSlow[aStart + 1]);
      bool fullTouchNext = (lo[aStart + 1] <= zDn && hi[aStart + 1] >= zUp);
      if(!fullTouchNext) break;
      aStart++;
   }

   // Build fib anchors (bullish: 100% = dip low at Touch A, 0% = peak between A and now)
   double fib100, fib0;
   int peakIdx = aEnd - 1;
   if(peakIdx < 0) peakIdx = 0;
   if(direction == TREND_BULLISH) {
      fib100 = lo[aEnd];
      for(int i = aEnd; i <= aStart; i++) if(lo[i] < fib100) fib100 = lo[i];
      fib0 = hi[peakIdx];
      for(int i = 1; i < aEnd; i++) if(hi[i] > fib0) { fib0 = hi[i]; peakIdx = i; }
   } else {
      fib100 = hi[aEnd];
      for(int i = aEnd; i <= aStart; i++) if(hi[i] > fib100) fib100 = hi[i];
      fib0 = lo[peakIdx];
      for(int i = 1; i < aEnd; i++) if(lo[i] < fib0) { fib0 = lo[i]; peakIdx = i; }
   }

   double legRange = MathAbs(fib0 - fib100);
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(legRange < point * 2.0) {
      reason = "degenerate fib leg (0% == 100%)";
      return false;
   }

   // Scan the pullback from the peak to the last closed bar:
   // deepest retracement, min-level touch, and return-to-0% after min touch
   double minLevel = FibMinRetracementPct / 100.0;
   double maxDepth = 0.0;
   bool reachedMin = false;
   bool cameBackTo0 = false;
   for(int i = peakIdx; i >= 1; i--) {
      double depth;
      if(direction == TREND_BULLISH) depth = (fib0 - lo[i]) / legRange;
      else                           depth = (hi[i] - fib0) / legRange;
      if(depth > maxDepth) maxDepth = depth;
      if(reachedMin) {
         bool touched0;
         if(direction == TREND_BULLISH) touched0 = (hi[i] >= fib0);
         else                           touched0 = (lo[i] <= fib0);
         if(touched0) cameBackTo0 = true;
      }
      if(depth >= minLevel) reachedMin = true;
   }

   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   string summary = "depth=" + DoubleToString(maxDepth * 100.0, 1) + "%" +
                    " min=" + DoubleToString(FibMinRetracementPct, 1) + "%" +
                    " fib0=" + DoubleToString(fib0, digits) +
                    " fib100=" + DoubleToString(fib100, digits) +
                    " A=" + IntegerToString(aEnd) + ".." + IntegerToString(aStart) +
                    " peak=" + IntegerToString(peakIdx);

   if(maxDepth > 1.0) {
      reason = "REJECTED beyond 100% - " + summary;
      return false;
   }
   if(maxDepth < minLevel) {
      reason = "REJECTED too shallow - " + summary;
      return false;
   }
   if(cameBackTo0) {
      reason = "REJECTED returned to 0% after min touch - " + summary;
      return false;
   }

   reason = "PASSED - " + summary;
   return true;
}

//+------------------------------------------------------------------+
//| Check M5 for Engulfing Entry                                     |
//+------------------------------------------------------------------+
void CheckM5Engulfing(int symbolIndex) {
   string symbol = g_symbols[symbolIndex].name;

   if(!IsNewBar(symbolIndex, TF_M5)) return;

   // Track M5 activity
   g_symbols[symbolIndex].lastM5BarCheck = TimeCurrent();
   g_symbols[symbolIndex].m5BarsAnalyzed++;

   ENGULF_TYPE engulf = DetectEngulfing(symbol, LTF_TIMEFRAME, 1);

   if(engulf == ENGULF_NONE) {
      g_symbols[symbolIndex].lastM5Result = "No engulfing pattern";
      Log("[" + symbol + " M5 BAR #" + IntegerToString(g_symbols[symbolIndex].m5BarsAnalyzed) + "] Checked - No engulfing pattern", "M5_CHECK");
      return;
   }

   bool validEngulf = false;
   if(g_symbols[symbolIndex].h1Direction == TREND_BULLISH) {
      validEngulf = (engulf == ENGULF_SINGLE_BULLISH || engulf == ENGULF_DOUBLE_BULLISH);
   } else if(g_symbols[symbolIndex].h1Direction == TREND_BEARISH) {
      validEngulf = (engulf == ENGULF_SINGLE_BEARISH || engulf == ENGULF_DOUBLE_BEARISH);
   }

   if(!validEngulf) {
      g_symbols[symbolIndex].lastM5Result = GetEngulfName(engulf) + " - Wrong direction";
      Log("[" + symbol + " M5 BAR #" + IntegerToString(g_symbols[symbolIndex].m5BarsAnalyzed) + "] Found " + GetEngulfName(engulf) + " but wrong direction", "M5_CHECK");
      return;
   }

   // NEW: Final confirmation - M5 EMA must still align with H1 direction before entry
   TREND_STATE m5EmaTrend = GetEMATrend(g_symbols[symbolIndex].emaFastHandle[TF_M5], g_symbols[symbolIndex].emaSlowHandle[TF_M5], 1);

   if(m5EmaTrend != g_symbols[symbolIndex].h1Direction) {
      g_symbols[symbolIndex].lastM5Result = GetEngulfName(engulf) + " - M5 EMA misaligned (" + GetTrendName(m5EmaTrend) + ")";
      Log("[" + symbol + " M5 BAR #" + IntegerToString(g_symbols[symbolIndex].m5BarsAnalyzed) + "] Found valid engulfing but M5 EMA (" +
          GetTrendName(m5EmaTrend) + ") doesn't match H1 (" + GetTrendName(g_symbols[symbolIndex].h1Direction) + ") - SIGNAL INVALIDATED", "M5_CHECK");
      Log("Resetting state - waiting for new H1 signal...", "M5_CHECK");
      ResetSymbolState(symbolIndex);
      return;
   }

   // NEW: Fibonacci retracement confirmation - pullback into retest must be deep enough
   if(UseFibConfirmation) {
      string fibReason = "";
      if(!CheckFibConfirmation(symbol, g_symbols[symbolIndex].emaFastHandle[TF_M5], g_symbols[symbolIndex].emaSlowHandle[TF_M5],
                               g_symbols[symbolIndex].h1Direction, g_symbols[symbolIndex].m5RetestTime, fibReason)) {
         g_symbols[symbolIndex].stats.fibRejections++;
         g_symbols[symbolIndex].lastM5Result = GetEngulfName(engulf) + " - Fib rejected: " + fibReason;
         Log("[" + symbol + " M5 BAR #" + IntegerToString(g_symbols[symbolIndex].m5BarsAnalyzed) + "] Valid engulfing but fib confirmation failed: " + fibReason + " - Skipping (still waiting for M5 engulfing)", "M5_FIB");
         return;
      }
      Log("[" + symbol + " M5 BAR #" + IntegerToString(g_symbols[symbolIndex].m5BarsAnalyzed) + "] Fib confirmation " + fibReason, "M5_FIB");
   }

   // Activity tracking - VALID M5 ENGULFING with EMA confirmation
   g_symbols[symbolIndex].lastM5Result = ">>> " + GetEngulfName(engulf) + " - ENTRY (EMA confirmed) <<<";

   Log("[" + symbol + " M5 BAR #" + IntegerToString(g_symbols[symbolIndex].m5BarsAnalyzed) + "] >>> M5 ENGULFING DETECTED <<<", "M5_ENTRY");
   Log("Type: " + GetEngulfName(engulf) + " | M5 EMA: " + GetTrendName(m5EmaTrend) + " (Aligned)", "M5_ENTRY");

   ExecuteTradeBatch(symbolIndex);
}

//+------------------------------------------------------------------+
//| Get Position Identifier after trade execution                     |
//| Waits for position to be registered and returns POSITION_IDENTIFIER|
//+------------------------------------------------------------------+
ulong GetPositionIdentifier(ulong orderTicket) {
   if(orderTicket == 0) return 0;

   // Wait for position to be registered (max 500ms)
   uint startTick = GetTickCount();
   while(GetTickCount() - startTick < 500 && !IsStopped()) {
      if(PositionSelectByTicket(orderTicket)) {
         ulong posId = PositionGetInteger(POSITION_IDENTIFIER);
         if(posId > 0) {
            return posId;
         }
      }
      Sleep(10);
   }

   // Fallback: return order ticket if position not found
   Log("Warning: Could not get POSITION_IDENTIFIER for order " + IntegerToString(orderTicket) + " - using order ticket", "WARN");
   return orderTicket;
}

//+------------------------------------------------------------------+
//| Validate Server Response                                          |
//| Parses server response and logs execution details                  |
//+------------------------------------------------------------------+
bool ValidateServerResponse(char &result[], string context) {
   if(ArraySize(result) == 0) {
      Log(context + " - Empty response from server", "WARN");
      return true;  // Treat empty as success (server may not return body)
   }

   string response = CharArrayToString(result);

   // Expected format: "OK|{signalId}|{successCount}/{totalAccounts}"
   if(StringFind(response, "OK|") == 0) {
      string parts[];
      int count = StringSplit(response, '|', parts);
      if(count >= 3) {
         Log(context + " - Server confirmed: " + parts[2] + " accounts", "BROADCAST");
      } else {
         Log(context + " - Server confirmed (OK)", "BROADCAST");
      }
      return true;
   }

   // Check for error responses
   if(StringFind(response, "AUTH_FAILED") >= 0) {
      Log(context + " - Authentication failed! Check API key", "ERROR");
      return false;
   }

   if(StringFind(response, "INVALID") >= 0) {
      Log(context + " - Invalid request: " + response, "ERROR");
      return false;
   }

   // Unknown response - log but treat as success if HTTP was 200
   Log(context + " - Server response: " + StringSubstr(response, 0, 100), "DEBUG");
   return true;
}

//+------------------------------------------------------------------+
//| Broadcast Signal to Server with Retry Logic                        |
//| Sends trading signal to server API for Telegram broadcast          |
//| Includes exponential backoff retry (3 attempts)                    |
//+------------------------------------------------------------------+
bool BroadcastSignalToServer(string action, string symbol, double entry,
                              double sl, double tp, double tp2, string pattern, double lots) {
   // Skip if broadcast is disabled or in optimization mode
   if(!BroadcastMode || g_isOptimization) return true;

   // Block broadcasts during Asian session
   if(IsAsianSession()) {
      Log("Signal broadcast BLOCKED: Asian session active | " + symbol + " " + action, "SESSION");
      return false;
   }

   // Build URL with query parameters
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);

   string url = BroadcastURL + "?api_key=" + BroadcastAPIKey +
                "&action=" + action +
                "&symbol=" + symbol +
                "&entry=" + DoubleToString(entry, digits) +
                "&sl=" + DoubleToString(sl, digits) +
                "&tp=" + DoubleToString(tp, digits) +
                "&tp2=" + DoubleToString(tp2, digits) +
                "&pattern=" + pattern +
                "&lots=" + DoubleToString(lots, 2) +
                "&riskAmount=" + DoubleToString(GetRiskAmount(), 2) +
                "&source=ForexEngulfingBot";

   string headers = "Content-Type: application/x-www-form-urlencoded\r\n";

   // Retry configuration: 3 attempts with exponential backoff
   int maxRetries = 3;
   int delays[] = {1000, 3000, 5000};  // 1s, 3s, 5s delays

   for(int attempt = 0; attempt < maxRetries; attempt++) {
      char post[], result[];
      string resultHeaders;

      ResetLastError();
      int res = WebRequest("POST", url, headers, 5000, post, result, resultHeaders);

      if(res == 200 || res == 201) {
         // Validate and log server response
         ValidateServerResponse(result, symbol + " " + action);
         Log("Signal broadcast SUCCESS: " + symbol + " " + action +
             (attempt > 0 ? " (attempt " + IntegerToString(attempt + 1) + ")" : ""), "BROADCAST");
         return true;
      }

      if(res == -1) {
         int error = GetLastError();
         if(error == 4014) {
            // WebRequest not allowed - no point retrying
            Log("Signal broadcast FAILED: WebRequest not allowed - Add server URL to MT5 allowed URLs (Tools > Options > Expert Advisors)", "ERROR");
            return false;
         }
         Log("Signal broadcast attempt " + IntegerToString(attempt + 1) +
             " FAILED: Error " + IntegerToString(error), "WARN");
      } else {
         Log("Signal broadcast attempt " + IntegerToString(attempt + 1) +
             " FAILED: HTTP " + IntegerToString(res), "WARN");
      }

      // Retry with delay (except on last attempt)
      if(attempt < maxRetries - 1) {
         Log("Retrying in " + IntegerToString(delays[attempt]) + "ms...", "INFO");
         Sleep(delays[attempt]);
      }
   }

   Log("Signal broadcast FAILED after " + IntegerToString(maxRetries) + " attempts: " + symbol + " " + action, "ERROR");
   return false;
}

//+------------------------------------------------------------------+
//| Broadcast Trade Close to Server with Retry Logic                  |
//| Sends trade close notification for Telegram broadcast              |
//| Includes exponential backoff retry (3 attempts)                    |
//+------------------------------------------------------------------+
void BroadcastTradeClose(string symbol, string action, double entry, double closePrice,
                          double profit, string reason) {
   // Skip if broadcast is disabled or in optimization mode
   if(!BroadcastMode || g_isOptimization) return;

   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);

   string url = BroadcastURL + "?api_key=" + BroadcastAPIKey +
                "&action=CLOSE" +
                "&symbol=" + symbol +
                "&direction=" + action +
                "&entry=" + DoubleToString(entry, digits) +
                "&closePrice=" + DoubleToString(closePrice, digits) +
                "&profit=" + DoubleToString(profit, 2) +
                "&reason=" + reason +
                "&source=ForexEngulfingBot";

   string headers = "Content-Type: application/x-www-form-urlencoded\r\n";

   // Retry configuration: 3 attempts with exponential backoff
   int maxRetries = 3;
   int delays[] = {1000, 3000, 5000};  // 1s, 3s, 5s delays

   for(int attempt = 0; attempt < maxRetries; attempt++) {
      char post[], result[];
      string resultHeaders;

      ResetLastError();
      int res = WebRequest("POST", url, headers, 5000, post, result, resultHeaders);

      if(res == 200 || res == 201) {
         Log("Trade close broadcast SUCCESS: " + symbol + " " + reason + " $" + DoubleToString(profit, 2) +
             (attempt > 0 ? " (attempt " + IntegerToString(attempt + 1) + ")" : ""), "BROADCAST");
         return;
      }

      if(res == -1) {
         int error = GetLastError();
         if(error == 4014) {
            // WebRequest not allowed - no point retrying
            Log("Trade close broadcast FAILED: WebRequest not allowed", "ERROR");
            return;
         }
         Log("Trade close broadcast attempt " + IntegerToString(attempt + 1) +
             " FAILED: Error " + IntegerToString(error), "WARN");
      } else {
         Log("Trade close broadcast attempt " + IntegerToString(attempt + 1) +
             " FAILED: HTTP " + IntegerToString(res), "WARN");
      }

      // Retry with delay (except on last attempt)
      if(attempt < maxRetries - 1) {
         Sleep(delays[attempt]);
      }
   }

   Log("Trade close broadcast FAILED after " + IntegerToString(maxRetries) + " attempts: " + symbol, "ERROR");
}

//+------------------------------------------------------------------+
//| Broadcast TP Hit to Server for Telegram Notification              |
//| Called when TP1 or TP2 is hit to notify all Telegram channels     |
//+------------------------------------------------------------------+
void BroadcastTPHit(string symbol, string action, int tpNumber, double entryPrice,
                    double tpPrice, double profit) {
   // Skip if broadcast mode is disabled or in optimization mode
   if(!BroadcastMode || g_isOptimization) return;

   // NOTE: Follow-up notifications (TP hits) are sent 24/7 by design - a trade opened
   // during a tradeable session can hit TP during the Asian session, so we must notify.

   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   string baseUrl = StringSubstr(BroadcastURL, 0, StringFind(BroadcastURL, "/ea"));
   string url = baseUrl + "/ea/tp-hit" +
                "?api_key=" + BroadcastAPIKey +
                "&symbol=" + symbol +
                "&direction=" + action +
                "&tpNumber=" + IntegerToString(tpNumber) +
                "&entry=" + DoubleToString(entryPrice, digits) +
                "&tpPrice=" + DoubleToString(tpPrice, digits) +
                "&profit=" + DoubleToString(profit, 2) +
                "&source=ForexEngulfingBot";

   string headers = "Content-Type: application/x-www-form-urlencoded\r\n";

   // Retry configuration: 3 attempts with exponential backoff
   int maxRetries = 3;
   int delays[] = {1000, 3000, 5000};

   for(int attempt = 0; attempt < maxRetries; attempt++) {
      char post[], result[];
      string resultHeaders;

      ResetLastError();
      int res = WebRequest("POST", url, headers, 5000, post, result, resultHeaders);

      if(res == 200 || res == 201) {
         Log("TP" + IntegerToString(tpNumber) + " hit broadcast SUCCESS: " + symbol + " $" + DoubleToString(profit, 2), "BROADCAST");
         return;
      }

      if(res == -1) {
         int error = GetLastError();
         if(error == 4014) {
            Log("TP hit broadcast FAILED: WebRequest not allowed", "ERROR");
            return;
         }
      }

      if(attempt < maxRetries - 1) {
         Sleep(delays[attempt]);
      }
   }

   Log("TP hit broadcast FAILED after " + IntegerToString(maxRetries) + " attempts: " + symbol, "ERROR");
}

//+------------------------------------------------------------------+
//| Broadcast Breakeven to Server for Telegram Notification           |
//| Called when SL is moved to breakeven to notify all channels       |
//+------------------------------------------------------------------+
void BroadcastBreakeven(string symbol, string action, double entryPrice) {
   // Skip if broadcast mode is disabled or in optimization mode
   if(!BroadcastMode || g_isOptimization) return;

   // NOTE: Follow-up notifications (breakeven) are sent 24/7 by design - break-even can
   // be triggered during the Asian session for a trade opened in a tradeable session.

   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   string baseUrl = StringSubstr(BroadcastURL, 0, StringFind(BroadcastURL, "/ea"));
   string url = baseUrl + "/ea/breakeven" +
                "?api_key=" + BroadcastAPIKey +
                "&symbol=" + symbol +
                "&direction=" + action +
                "&entry=" + DoubleToString(entryPrice, digits) +
                "&source=ForexEngulfingBot";

   string headers = "Content-Type: application/x-www-form-urlencoded\r\n";

   // Retry configuration: 3 attempts with exponential backoff
   int maxRetries = 3;
   int delays[] = {1000, 3000, 5000};

   for(int attempt = 0; attempt < maxRetries; attempt++) {
      char post[], result[];
      string resultHeaders;

      ResetLastError();
      int res = WebRequest("POST", url, headers, 5000, post, result, resultHeaders);

      if(res == 200 || res == 201) {
         Log("Breakeven broadcast SUCCESS: " + symbol + " entry=" + DoubleToString(entryPrice, digits), "BROADCAST");
         return;
      }

      if(res == -1) {
         int error = GetLastError();
         if(error == 4014) {
            Log("Breakeven broadcast FAILED: WebRequest not allowed", "ERROR");
            return;
         }
      }

      if(attempt < maxRetries - 1) {
         Sleep(delays[attempt]);
      }
   }

   Log("Breakeven broadcast FAILED after " + IntegerToString(maxRetries) + " attempts: " + symbol, "ERROR");
}

//+------------------------------------------------------------------+
//| Broadcast Combined TP1 + Breakeven to Server                      |
//| Single notification: TP1 was hit AND Trade 2 BE outcome           |
//| Sent 24/7 by design (follow-up to an already-open trade).         |
//+------------------------------------------------------------------+
void BroadcastTP1Breakeven(string symbol, string direction, double entry, double tpPrice,
                           double profit, bool beSuccess, double beSL) {
   // Skip if broadcast mode is disabled or in optimization mode
   if(!BroadcastMode || g_isOptimization) return;

   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   string baseUrl = StringSubstr(BroadcastURL, 0, StringFind(BroadcastURL, "/ea"));
   string url = baseUrl + "/ea/tp1-breakeven" +
                "?api_key=" + BroadcastAPIKey +
                "&symbol=" + symbol +
                "&direction=" + direction +
                "&entry=" + DoubleToString(entry, digits) +
                "&tpPrice=" + DoubleToString(tpPrice, digits) +
                "&profit=" + DoubleToString(profit, 2) +
                "&beSuccess=" + (beSuccess ? "true" : "false") +
                "&beSL=" + DoubleToString(beSL, digits) +
                "&source=ForexEngulfingBot";

   string headers = "Content-Type: application/x-www-form-urlencoded\r\n";

   // Retry configuration: 3 attempts with exponential backoff
   int maxRetries = 3;
   int delays[] = {1000, 3000, 5000};

   for(int attempt = 0; attempt < maxRetries; attempt++) {
      char post[], result[];
      string resultHeaders;

      ResetLastError();
      int res = WebRequest("POST", url, headers, 5000, post, result, resultHeaders);

      if(res == 200 || res == 201) {
         Log("TP1+BE broadcast SUCCESS: " + symbol + " " + direction +
             " | beSuccess=" + (beSuccess ? "true" : "false") + " $" + DoubleToString(profit, 2), "BROADCAST");
         return;
      }

      if(res == -1) {
         int error = GetLastError();
         if(error == 4014) {
            Log("TP1+BE broadcast FAILED: WebRequest not allowed", "ERROR");
            return;
         }
      }

      if(attempt < maxRetries - 1) {
         Sleep(delays[attempt]);
      }
   }

   Log("TP1+BE broadcast FAILED after " + IntegerToString(maxRetries) + " attempts: " + symbol, "ERROR");
}

//+------------------------------------------------------------------+
//| Send Account Heartbeat to Server                                  |
//| Periodic ping with balance/equity/margin so the dashboard stays   |
//| current even when no signals are firing. Sent 24/7.               |
//+------------------------------------------------------------------+
void SendAccountHeartbeat() {
   if(!BroadcastMode || g_isOptimization) return;

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double margin = AccountInfoDouble(ACCOUNT_MARGIN);
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);

   if(balance <= 0) return;

   // Count open positions for this EA (magic-filtered)
   int openPositions = 0;
   for(int p = PositionsTotal() - 1; p >= 0; p--) {
      if(PositionSelectByTicket(PositionGetTicket(p))) {
         if(PositionGetInteger(POSITION_MAGIC) == MagicNumber) {
            openPositions++;
         }
      }
   }

   string baseUrl = StringSubstr(BroadcastURL, 0, StringFind(BroadcastURL, "/ea"));
   string url = baseUrl + "/ea/account" +
                "?api_key=" + BroadcastAPIKey +
                "&balance=" + DoubleToString(balance, 2) +
                "&equity=" + DoubleToString(equity, 2) +
                "&margin=" + DoubleToString(margin, 2) +
                "&freeMargin=" + DoubleToString(freeMargin, 2) +
                "&openPositions=" + IntegerToString(openPositions) +
                "&source=ForexEngulfingBot";

   string headers = "Content-Type: application/x-www-form-urlencoded\r\n";
   char post[], result[];
   string resultHeaders;

   ResetLastError();
   int res = WebRequest("POST", url, headers, 5000, post, result, resultHeaders);

   if(res == 200 || res == 201) {
      LogVerbose("Account heartbeat sent: bal=$" + DoubleToString(balance, 2) +
                 " eq=$" + DoubleToString(equity, 2) + " open=" + IntegerToString(openPositions), "HEARTBEAT");
   } else if(res == -1) {
      int error = GetLastError();
      if(error == 4014) {
         Log("Account heartbeat FAILED: WebRequest not allowed", "ERROR");
      } else {
         LogVerbose("Account heartbeat failed: Error " + IntegerToString(error), "HEARTBEAT");
      }
   } else {
      LogVerbose("Account heartbeat failed: HTTP " + IntegerToString(res), "HEARTBEAT");
   }
}

//+------------------------------------------------------------------+
//| Execute Trade Batch                                              |
//+------------------------------------------------------------------+
void ExecuteTradeBatch(int symbolIndex) {
   string symbol = g_symbols[symbolIndex].name;
   int digits = g_symbols[symbolIndex].calc.GetDigits();
   bool isBuy = (g_symbols[symbolIndex].h1Direction == TREND_BULLISH);

   // Check per-symbol trade limit
   if(!CheckSymbolTradeLimit(symbolIndex)) {
      Log(symbol + " daily trade limit reached (" +
          IntegerToString(g_symbols[symbolIndex].dailyTrades) + "/" +
          IntegerToString(g_symbols[symbolIndex].maxTradesPerDay) + ") - No new trades", "LIMIT");
      g_symbols[symbolIndex].lastM5Result = "LIMIT REACHED (" +
          IntegerToString(g_symbols[symbolIndex].dailyTrades) + "/" +
          IntegerToString(g_symbols[symbolIndex].maxTradesPerDay) + ")";
      return;
   }

   Log("==========================================", "TRADE");
   Log(">>> " + symbol + " EXECUTING TRADE BATCH " + IntegerToString(g_symbols[symbolIndex].batchCount + 1) + " <<<", "TRADE");

   if(!g_symbols[symbolIndex].calc.IsSpreadOK()) {
      Log("Spread too high: " + DoubleToString(g_symbols[symbolIndex].calc.GetSpreadPips(), 1) + " pips - SKIPPING", "TRADE");
      return;
   }

   double entry = isBuy ? SymbolInfoDouble(symbol, SYMBOL_ASK) : SymbolInfoDouble(symbol, SYMBOL_BID);

   double atr = GetATR(g_symbols[symbolIndex].atrHandle[TF_M5], 1);
   double slDistance = atr * ATR_Multiplier;
   double slPips = g_symbols[symbolIndex].calc.ToPips(slDistance) + SpreadBufferPips;

   if(slPips < MinSLPips) slPips = MinSLPips;
   if(slPips > MaxSLPips) slPips = MaxSLPips;

   slDistance = g_symbols[symbolIndex].calc.ToPrice(slPips);

   double sl = isBuy ? entry - slDistance : entry + slDistance;

   double tp1Distance = slDistance * RR_Trade1;
   double tp2Distance = slDistance * RR_Trade2;

   double tp1 = isBuy ? entry + tp1Distance : entry - tp1Distance;
   double tp2 = isBuy ? entry + tp2Distance : entry - tp2Distance;

   double lots = CalculateLotSize(symbolIndex, slPips);

   if(lots < g_symbols[symbolIndex].calc.GetMinLot()) {
      Log("Lot size too small - SKIPPING", "TRADE");
      return;
   }

   Log("Entry: " + DoubleToString(entry, digits), "TRADE");
   Log("SL: " + DoubleToString(sl, digits) + " (" + DoubleToString(slPips, 1) + " pips)", "TRADE");
   Log("TP1: " + DoubleToString(tp1, digits) + " | TP2: " + DoubleToString(tp2, digits), "TRADE");
   Log("Lots: " + DoubleToString(lots, 2), "TRADE");

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(30);

   bool success1 = false;
   bool success2 = false;

   // Trade 1 (1:1 RR)
   string comment1 = "FX_B" + IntegerToString(g_symbols[symbolIndex].batchCount + 1) + "_T1_" + (isBuy ? "BUY" : "SELL");

   if(isBuy) {
      success1 = trade.Buy(lots, symbol, 0, sl, tp1, comment1);
   } else {
      success1 = trade.Sell(lots, symbol, 0, sl, tp1, comment1);
   }

   if(success1) {
      ulong orderTicket1 = trade.ResultOrder();
      ulong posId1 = GetPositionIdentifier(orderTicket1);
      Log("Trade 1 OPENED - Ticket: " + IntegerToString(orderTicket1) + " | PosID: " + IntegerToString(posId1), "SUCCESS");

      if(g_symbols[symbolIndex].batchCount == 0) {
         g_symbols[symbolIndex].trade1_1.ticket = orderTicket1;
         g_symbols[symbolIndex].trade1_1.positionId = posId1;
         g_symbols[symbolIndex].trade1_1.entryPrice = trade.ResultPrice();
         g_symbols[symbolIndex].trade1_1.sl = sl;
         g_symbols[symbolIndex].trade1_1.tp = tp1;
         g_symbols[symbolIndex].trade1_1.lots = lots;
         g_symbols[symbolIndex].trade1_1.rrRatio = RR_Trade1;
         g_symbols[symbolIndex].trade1_1.isOpen = true;
         g_symbols[symbolIndex].trade1_1.hitTP = false;
         g_symbols[symbolIndex].trade1_1.openTime = TimeCurrent();
      } else {
         g_symbols[symbolIndex].trade2_1.ticket = orderTicket1;
         g_symbols[symbolIndex].trade2_1.positionId = posId1;
         g_symbols[symbolIndex].trade2_1.entryPrice = trade.ResultPrice();
         g_symbols[symbolIndex].trade2_1.sl = sl;
         g_symbols[symbolIndex].trade2_1.tp = tp1;
         g_symbols[symbolIndex].trade2_1.lots = lots;
         g_symbols[symbolIndex].trade2_1.rrRatio = RR_Trade1;
         g_symbols[symbolIndex].trade2_1.isOpen = true;
         g_symbols[symbolIndex].trade2_1.hitTP = false;
         g_symbols[symbolIndex].trade2_1.openTime = TimeCurrent();
      }

      g_dailyTrades++;
      g_symbols[symbolIndex].dailyTrades++;  // Per-symbol counter
   } else {
      Log("Trade 1 FAILED: " + trade.ResultRetcodeDescription(), "ERROR");
   }

   // Trade 2 (1:2 RR)
   string comment2 = "FX_B" + IntegerToString(g_symbols[symbolIndex].batchCount + 1) + "_T2_" + (isBuy ? "BUY" : "SELL");

   if(isBuy) {
      success2 = trade.Buy(lots, symbol, 0, sl, tp2, comment2);
   } else {
      success2 = trade.Sell(lots, symbol, 0, sl, tp2, comment2);
   }

   if(success2) {
      ulong orderTicket2 = trade.ResultOrder();
      ulong posId2 = GetPositionIdentifier(orderTicket2);
      Log("Trade 2 OPENED - Ticket: " + IntegerToString(orderTicket2) + " | PosID: " + IntegerToString(posId2), "SUCCESS");

      if(g_symbols[symbolIndex].batchCount == 0) {
         g_symbols[symbolIndex].trade1_2.ticket = orderTicket2;
         g_symbols[symbolIndex].trade1_2.positionId = posId2;
         g_symbols[symbolIndex].trade1_2.entryPrice = trade.ResultPrice();
         g_symbols[symbolIndex].trade1_2.sl = sl;
         g_symbols[symbolIndex].trade1_2.tp = tp2;
         g_symbols[symbolIndex].trade1_2.lots = lots;
         g_symbols[symbolIndex].trade1_2.rrRatio = RR_Trade2;
         g_symbols[symbolIndex].trade1_2.isOpen = true;
         g_symbols[symbolIndex].trade1_2.hitTP = false;
         g_symbols[symbolIndex].trade1_2.breakevenSet = false;
         g_symbols[symbolIndex].trade1_2.openTime = TimeCurrent();
      } else {
         g_symbols[symbolIndex].trade2_2.ticket = orderTicket2;
         g_symbols[symbolIndex].trade2_2.positionId = posId2;
         g_symbols[symbolIndex].trade2_2.entryPrice = trade.ResultPrice();
         g_symbols[symbolIndex].trade2_2.sl = sl;
         g_symbols[symbolIndex].trade2_2.tp = tp2;
         g_symbols[symbolIndex].trade2_2.lots = lots;
         g_symbols[symbolIndex].trade2_2.rrRatio = RR_Trade2;
         g_symbols[symbolIndex].trade2_2.isOpen = true;
         g_symbols[symbolIndex].trade2_2.hitTP = false;
         g_symbols[symbolIndex].trade2_2.breakevenSet = false;
         g_symbols[symbolIndex].trade2_2.openTime = TimeCurrent();
      }

      g_dailyTrades++;
      g_symbols[symbolIndex].dailyTrades++;  // Per-symbol counter
   } else {
      Log("Trade 2 FAILED: " + trade.ResultRetcodeDescription(), "ERROR");
   }

   // Only increment if at least one succeeded
   if(success1 || success2) {
      g_symbols[symbolIndex].batchCount++;
      g_symbols[symbolIndex].stats.h1SignalsTraded++;

      if(g_symbols[symbolIndex].batchCount == 1) {
         g_symbols[symbolIndex].stats.batch1Trades += (success1 ? 1 : 0) + (success2 ? 1 : 0);
      } else {
         g_symbols[symbolIndex].stats.batch2Trades += (success1 ? 1 : 0) + (success2 ? 1 : 0);
      }

      if(g_symbols[symbolIndex].batchCount >= MaxBatchesPerH1Signal) {
         g_symbols[symbolIndex].signalState = STATE_SIGNAL_COMPLETE;
      } else {
         g_symbols[symbolIndex].signalState = (g_symbols[symbolIndex].batchCount == 1) ? STATE_BATCH1_ACTIVE : STATE_BATCH2_ACTIVE;
      }
   }

   g_symbols[symbolIndex].m5RetestDetected = false;
   g_symbols[symbolIndex].m5EngulfDetected = false;

   Log("==========================================", "TRADE");

   // Broadcast signal to server (non-blocking)
   if(success1 || success2) {
      string action = isBuy ? "BUY" : "SELL";
      string pattern = GetEngulfName(g_symbols[symbolIndex].h1EngulfType);
      BroadcastSignalToServer(action, symbol, entry, sl, tp1, tp2, pattern, lots);

      // Persist tracking so an EA/terminal restart can resume monitoring these trades
      PersistState(symbolIndex);
   }
}

//+------------------------------------------------------------------+
//| Select a tracked position using its IDENTIFIER (preferred) with   |
//| an order-ticket fallback. Prevents an order-ticket/position-id    |
//| mismatch from falsely marking a still-open trade as closed.       |
//+------------------------------------------------------------------+
bool SelectTradePosition(const TradeInfo &t) {
   if(t.positionId > 0 && PositionSelectByTicket(t.positionId)) return true;
   if(t.ticket > 0 && PositionSelectByTicket(t.ticket)) return true;
   return false;
}

//+------------------------------------------------------------------+
//| Send the combined TP1 + Breakeven notification exactly once.      |
//| beSuccess reports whether Trade 2's SL is now at break-even.      |
//+------------------------------------------------------------------+
void NotifyTP1Breakeven(int symbolIndex, TradeInfo &t1, TradeInfo &t2, bool beSuccess) {
   if(t1.notified) return;
   string symbol = g_symbols[symbolIndex].name;
   string direction = (t1.tp > t1.entryPrice) ? "BUY" : "SELL";
   double beSL = beSuccess ? t2.sl : 0.0;
   BroadcastTP1Breakeven(symbol, direction, t1.entryPrice, t1.tp, 0, beSuccess, beSL);
   t1.notified = true;
   PersistState(symbolIndex);
}

//+------------------------------------------------------------------+
//| Handle Trade-1 TP -> move Trade-2 to break-even -> notify once.   |
//| On BE failure, arms a pending retry (ProcessPendingBreakeven).    |
//+------------------------------------------------------------------+
void HandleTP1Breakeven(int symbolIndex, TradeInfo &t1, TradeInfo &t2, string label) {
   if(!(AutoBreakeven && t2.ticket > 0)) {
      // Auto-breakeven disabled or no Trade 2 - still send the combined notice once
      NotifyTP1Breakeven(symbolIndex, t1, t2, false);
      return;
   }

   if(t2.breakevenSet) {
      NotifyTP1Breakeven(symbolIndex, t1, t2, true);
      return;
   }

   // Verify Trade 2 still exists (identifier-first selection)
   if(!SelectTradePosition(t2)) {
      t2.isOpen = false;
      Log(label + " Trade 2 already closed - breakeven not applicable", "BREAKEVEN");
      NotifyTP1Breakeven(symbolIndex, t1, t2, false);
      return;
   }

   Log(label + " Trade 1 hit TP - moving Trade 2 to breakeven...", "BREAKEVEN");
   bool beResult = MoveToBreakeven(t2.ticket, t2.entryPrice);
   if(beResult) {
      t2.breakevenSet = true;
      t2.bePending = false;
      t2.bePendingTicks = 0;
      if(SelectTradePosition(t2)) t2.sl = PositionGetDouble(POSITION_SL);
      NotifyTP1Breakeven(symbolIndex, t1, t2, true);
   } else {
      // Do NOT mark breakevenSet - arm a cross-tick pending retry instead
      t2.bePending = true;
      t2.bePendingTicks = 1;
      Log(label + " Breakeven attempt failed - retrying every tick (err=" +
          IntegerToString(GetLastError()) + ")", "BREAKEVEN");
      PersistState(symbolIndex);
   }
}

//+------------------------------------------------------------------+
//| Retry pending break-evens every tick until success or position    |
//| gone. After N failed ticks, fire the loud BE-FAILED notification  |
//| once (retries continue in the background).                        |
//+------------------------------------------------------------------+
void ProcessPendingBreakeven(int symbolIndex, TradeInfo &t1, TradeInfo &t2, string label) {
   if(!t2.bePending) return;

   // Position no longer exists - stop retrying
   if(!SelectTradePosition(t2)) {
      t2.bePending = false;
      t2.isOpen = false;
      Log(label + " Pending BE aborted - Trade 2 position gone", "BREAKEVEN");
      NotifyTP1Breakeven(symbolIndex, t1, t2, false);
      return;
   }

   t2.bePendingTicks++;
   bool beResult = MoveToBreakeven(t2.ticket, t2.entryPrice);
   if(beResult) {
      t2.breakevenSet = true;
      t2.bePending = false;
      if(SelectTradePosition(t2)) t2.sl = PositionGetDouble(POSITION_SL);
      Log(label + " Pending BE SUCCEEDED on tick " + IntegerToString(t2.bePendingTicks), "BREAKEVEN");
      NotifyTP1Breakeven(symbolIndex, t1, t2, true);
   } else {
      Log(label + " Pending BE retry " + IntegerToString(t2.bePendingTicks) +
          " failed (err=" + IntegerToString(GetLastError()) + " | " + trade.ResultRetcodeDescription() + ")", "BREAKEVEN");
      // After 5 failed ticks, send the loud BE-FAILED warning once; keep retrying
      if(t2.bePendingTicks >= 5 && !t1.notified) {
         Log(label + " BE FAILED after 5 ticks - sending BE-FAILED warning (retries continue)", "BREAKEVEN");
         NotifyTP1Breakeven(symbolIndex, t1, t2, false);
      }
      PersistState(symbolIndex);
   }
}

//+------------------------------------------------------------------+
//| Monitor Active Trades                                            |
//+------------------------------------------------------------------+
void MonitorTrades(int symbolIndex) {
   string symbol = g_symbols[symbolIndex].name;

   // Retry any pending break-evens first so a freeze/requote that blocked the
   // initial attempt resolves on a later tick rather than being abandoned.
   ProcessPendingBreakeven(symbolIndex, g_symbols[symbolIndex].trade1_1, g_symbols[symbolIndex].trade1_2, symbol + " B1");
   ProcessPendingBreakeven(symbolIndex, g_symbols[symbolIndex].trade2_1, g_symbols[symbolIndex].trade2_2, symbol + " B2");

   if(g_symbols[symbolIndex].signalState == STATE_BATCH1_ACTIVE) {
      if(g_symbols[symbolIndex].trade1_1.isOpen && g_symbols[symbolIndex].trade1_1.ticket > 0) {
         if(!SelectTradePosition(g_symbols[symbolIndex].trade1_1)) {
            g_symbols[symbolIndex].trade1_1.isOpen = false;
            UpdateTradeStats(symbolIndex, g_symbols[symbolIndex].trade1_1, true);

            if(CheckIfTPHit(g_symbols[symbolIndex].trade1_1.positionId)) {
               g_symbols[symbolIndex].trade1_1.hitTP = true;
               g_symbols[symbolIndex].stats.trade1_1_TPHits++;
               Log(symbol + " Trade 1 (1:1 RR) HIT TP - PosID: " + IntegerToString(g_symbols[symbolIndex].trade1_1.positionId), "TP_HIT");

               // Move Trade 2 to break-even FIRST, then send ONE combined TP1+BE notice
               HandleTP1Breakeven(symbolIndex, g_symbols[symbolIndex].trade1_1, g_symbols[symbolIndex].trade1_2, symbol + " B1");
            } else {
               Log(symbol + " Trade 1 (1:1 RR) closed (SL or manual)", "TRADE");
            }
            PersistState(symbolIndex);
         }
      }

      if(g_symbols[symbolIndex].trade1_2.isOpen && g_symbols[symbolIndex].trade1_2.ticket > 0) {
         if(!SelectTradePosition(g_symbols[symbolIndex].trade1_2)) {
            g_symbols[symbolIndex].trade1_2.isOpen = false;
            g_symbols[symbolIndex].trade1_2.bePending = false;
            UpdateTradeStats(symbolIndex, g_symbols[symbolIndex].trade1_2, false);

            if(CheckIfTPHit(g_symbols[symbolIndex].trade1_2.positionId)) {
               g_symbols[symbolIndex].trade1_2.hitTP = true;
               g_symbols[symbolIndex].stats.trade1_2_TPHits++;
               Log(symbol + " Trade 2 (1:2 RR) HIT TP", "TP_HIT");

               // Broadcast TP2 hit to Telegram channels
               string direction = (g_symbols[symbolIndex].trade1_2.tp > g_symbols[symbolIndex].trade1_2.entryPrice) ? "BUY" : "SELL";
               BroadcastTPHit(symbol, direction, 2, g_symbols[symbolIndex].trade1_2.entryPrice, g_symbols[symbolIndex].trade1_2.tp, 0);
            } else {
               Log(symbol + " Trade 2 (1:2 RR) closed (SL or manual)", "TRADE");
            }
            PersistState(symbolIndex);
         }
      }

      bool bothClosed = !g_symbols[symbolIndex].trade1_1.isOpen && !g_symbols[symbolIndex].trade1_2.isOpen;

      if(bothClosed) {
         if(g_symbols[symbolIndex].trade1_1.hitTP && g_symbols[symbolIndex].batchCount < MaxBatchesPerH1Signal) {
            g_symbols[symbolIndex].signalState = STATE_WAITING_M5_RETEST2;
            g_symbols[symbolIndex].m5RetestDetected = false;
            Log(symbol + " Batch 1 complete - Waiting for second M5 retest...", "STATE");
         } else {
            g_symbols[symbolIndex].signalState = STATE_SIGNAL_COMPLETE;
            Log(symbol + " Batch 1 complete - Signal finished", "STATE");
         }
      }
   }

   if(g_symbols[symbolIndex].signalState == STATE_BATCH2_ACTIVE) {
      if(g_symbols[symbolIndex].trade2_1.isOpen && g_symbols[symbolIndex].trade2_1.ticket > 0) {
         if(!SelectTradePosition(g_symbols[symbolIndex].trade2_1)) {
            g_symbols[symbolIndex].trade2_1.isOpen = false;
            UpdateTradeStats(symbolIndex, g_symbols[symbolIndex].trade2_1, true);

            if(CheckIfTPHit(g_symbols[symbolIndex].trade2_1.positionId)) {
               g_symbols[symbolIndex].trade2_1.hitTP = true;
               Log(symbol + " Batch 2 Trade 1 (1:1 RR) HIT TP - PosID: " + IntegerToString(g_symbols[symbolIndex].trade2_1.positionId), "TP_HIT");

               // Move Trade 2 to break-even FIRST, then send ONE combined TP1+BE notice
               HandleTP1Breakeven(symbolIndex, g_symbols[symbolIndex].trade2_1, g_symbols[symbolIndex].trade2_2, symbol + " B2");
            } else {
               Log(symbol + " Batch 2 Trade 1 closed (SL or manual)", "TRADE");
            }
            PersistState(symbolIndex);
         }
      }

      if(g_symbols[symbolIndex].trade2_2.isOpen && g_symbols[symbolIndex].trade2_2.ticket > 0) {
         if(!SelectTradePosition(g_symbols[symbolIndex].trade2_2)) {
            g_symbols[symbolIndex].trade2_2.isOpen = false;
            g_symbols[symbolIndex].trade2_2.bePending = false;
            UpdateTradeStats(symbolIndex, g_symbols[symbolIndex].trade2_2, false);

            if(CheckIfTPHit(g_symbols[symbolIndex].trade2_2.positionId)) {
               g_symbols[symbolIndex].trade2_2.hitTP = true;
               Log(symbol + " Batch 2 Trade 2 (1:2 RR) HIT TP", "TP_HIT");

               // Broadcast TP2 hit to Telegram channels
               string direction = (g_symbols[symbolIndex].trade2_2.tp > g_symbols[symbolIndex].trade2_2.entryPrice) ? "BUY" : "SELL";
               BroadcastTPHit(symbol, direction, 2, g_symbols[symbolIndex].trade2_2.entryPrice, g_symbols[symbolIndex].trade2_2.tp, 0);
            } else {
               Log(symbol + " Batch 2 Trade 2 closed (SL or manual)", "TRADE");
            }
            PersistState(symbolIndex);
         }
      }

      if(!g_symbols[symbolIndex].trade2_1.isOpen && !g_symbols[symbolIndex].trade2_2.isOpen) {
         g_symbols[symbolIndex].signalState = STATE_SIGNAL_COMPLETE;
         Log(symbol + " Batch 2 complete - Signal finished", "STATE");
      }
   }

   if(g_symbols[symbolIndex].signalState == STATE_SIGNAL_COMPLETE) {
      Log(symbol + " Resetting for new H1 signal", "RESET");
      ResetSymbolState(symbolIndex);
   }
}

//+------------------------------------------------------------------+
//| Update Trade Stats                                               |
//+------------------------------------------------------------------+
void UpdateTradeStats(int symbolIndex, TradeInfo &t, bool isTrade1) {
   ulong positionId = t.positionId;
   if(positionId == 0) return;
   string symbol = g_symbols[symbolIndex].name;

   // Select history using position identifier
   if(!HistorySelectByPosition(positionId)) {
      HistorySelect(TimeCurrent() - 86400 * 7, TimeCurrent());
   }

   double profit = 0;
   double entryPrice = 0;
   double closePrice = 0;
   string action = "";
   int deals = HistoryDealsTotal();

   // First pass: get entry deal info
   for(int i = 0; i < deals; i++) {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0) continue;

      ulong posId = HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
      if(posId == positionId) {
         ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
         if(entry == DEAL_ENTRY_IN) {
            entryPrice = HistoryDealGetDouble(dealTicket, DEAL_PRICE);
            ENUM_DEAL_TYPE dealType = (ENUM_DEAL_TYPE)HistoryDealGetInteger(dealTicket, DEAL_TYPE);
            action = (dealType == DEAL_TYPE_BUY) ? "BUY" : "SELL";
         }
      }
   }

   // Second pass: get close deal info
   for(int i = deals - 1; i >= 0; i--) {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0) continue;

      ulong posId = HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
      if(posId == positionId) {
         ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
         if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY) {
            closePrice = HistoryDealGetDouble(dealTicket, DEAL_PRICE);
            profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
            profit += HistoryDealGetDouble(dealTicket, DEAL_SWAP);
            profit += HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
            break;
         }
      }
   }

   g_symbols[symbolIndex].stats.totalTrades++;
   g_symbols[symbolIndex].stats.netProfit += profit;

   // Track drawdown
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(currentBalance > g_peakBalance) {
      g_peakBalance = currentBalance;
   }
   double drawdown = g_peakBalance - currentBalance;
   if(drawdown > g_maxDrawdown) {
      g_maxDrawdown = drawdown;
   }

   if(profit > 0) {
      g_symbols[symbolIndex].stats.wins++;
      g_symbols[symbolIndex].stats.grossProfit += profit;
      if(profit > g_symbols[symbolIndex].stats.largestWin) {
         g_symbols[symbolIndex].stats.largestWin = profit;
      }

      g_symbols[symbolIndex].stats.consecutiveWins++;
      g_symbols[symbolIndex].stats.consecutiveLosses = 0;
      if(g_symbols[symbolIndex].stats.consecutiveWins > g_symbols[symbolIndex].stats.maxConsecutiveWins) {
         g_symbols[symbolIndex].stats.maxConsecutiveWins = g_symbols[symbolIndex].stats.consecutiveWins;
      }
   } else if(profit < 0) {
      g_symbols[symbolIndex].stats.losses++;
      g_symbols[symbolIndex].stats.grossLoss += profit;
      if(profit < g_symbols[symbolIndex].stats.largestLoss) {
         g_symbols[symbolIndex].stats.largestLoss = profit;
      }

      g_symbols[symbolIndex].stats.consecutiveLosses++;
      g_symbols[symbolIndex].stats.consecutiveWins = 0;
      if(g_symbols[symbolIndex].stats.consecutiveLosses > g_symbols[symbolIndex].stats.maxConsecutiveLosses) {
         g_symbols[symbolIndex].stats.maxConsecutiveLosses = g_symbols[symbolIndex].stats.consecutiveLosses;
      }
   }

   // Broadcast trade close to server (non-blocking) - once per slot
   if(action != "" && entryPrice > 0 && closePrice > 0 && !t.closeNotified) {
      string reason;
      if(profit > 0) {
         reason = "TP_HIT";
      } else if(t.breakevenSet &&
                MathAbs(closePrice - t.entryPrice) <= g_symbols[symbolIndex].calc.GetPipSize() * (BreakevenBufferPips + 1)) {
         // Closed at (or near) the break-even SL after Trade 1's TP
         reason = "BE_STOP";
      } else {
         reason = "SL_HIT";
      }
      BroadcastTradeClose(symbol, action, entryPrice, closePrice, profit, reason);
      t.closeNotified = true;
   }
}

//+------------------------------------------------------------------+
//| Check if Trade Hit TP (uses POSITION_IDENTIFIER for history)     |
//+------------------------------------------------------------------+
bool CheckIfTPHit(ulong positionId) {
   if(positionId == 0) return false;

   // Select history using position identifier
   if(!HistorySelectByPosition(positionId)) {
      HistorySelect(TimeCurrent() - 86400, TimeCurrent());
   }

   int deals = HistoryDealsTotal();
   for(int i = deals - 1; i >= 0; i--) {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0) continue;

      ulong posId = HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
      if(posId == positionId) {
         ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
         if(entry == DEAL_ENTRY_OUT) {
            double profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
            Log("CheckIfTPHit: PosID " + IntegerToString(positionId) + " closed with profit: " + DoubleToString(profit, 2), "DEBUG");
            return (profit > 0);
         }
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Move Position Stop Loss to Breakeven                             |
//+------------------------------------------------------------------+
bool MoveToBreakeven(ulong ticket, double entryPrice) {
   if(ticket == 0) return false;

   // Check if position still exists
   if(!PositionSelectByTicket(ticket)) {
      Log("Position " + IntegerToString(ticket) + " no longer exists - skipping breakeven", "BE");
      return false;
   }

   // Get position info
   double currentSL = PositionGetDouble(POSITION_SL);
   double currentTP = PositionGetDouble(POSITION_TP);
   string symbol = PositionGetString(POSITION_SYMBOL);
   ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

   // Get symbol properties
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);

   // Calculate pip size based on symbol type (handles all broker digit configurations)
   // JPY pairs: pip = 0.01 (regardless of 2 or 3 digit broker)
   // Major pairs: pip = 0.0001 (regardless of 4 or 5 digit broker)
   string symUpper = symbol;
   StringToUpper(symUpper);
   double pipSize = (StringFind(symUpper, "JPY") >= 0) ? 0.01 : 0.0001;

   // Calculate breakeven with configurable buffer (default 5 pips)
   double buffer = pipSize * BreakevenBufferPips;

   double newSL;
   if(posType == POSITION_TYPE_BUY) {
      newSL = NormalizeDouble(entryPrice + buffer, digits);
      // Only move if new SL is better (higher for buys)
      if(newSL <= currentSL) {
         Log(symbol + " Breakeven SL (" + DoubleToString(newSL, digits) + ") not better than current SL (" +
             DoubleToString(currentSL, digits) + ") - skipping", "BE");
         return false;
      }
   } else {
      newSL = NormalizeDouble(entryPrice - buffer, digits);
      // Only move if new SL is better (lower for sells)
      if(newSL >= currentSL) {
         Log(symbol + " Breakeven SL (" + DoubleToString(newSL, digits) + ") not better than current SL (" +
             DoubleToString(currentSL, digits) + ") - skipping", "BE");
         return false;
      }
   }

   // Get current price for level checks
   double currentPrice = (posType == POSITION_TYPE_BUY) ?
      SymbolInfoDouble(symbol, SYMBOL_BID) : SymbolInfoDouble(symbol, SYMBOL_ASK);

   // Check freeze level before modification
   long freezeLevelPoints = SymbolInfoInteger(symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   double freezeLevel = freezeLevelPoints * point;

   if(freezeLevel > 0 && MathAbs(currentPrice - newSL) < freezeLevel) {
      Log(symbol + " Freeze level violation (distance: " + DoubleToString(MathAbs(currentPrice - newSL), digits) +
          " < freeze: " + DoubleToString(freezeLevel, digits) + ") - cannot modify SL yet", "BE");
      return false;
   }

   // Check STOPS_LEVEL - minimum distance for stop orders from current price
   long stopsLevelPoints = SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double stopsLevel = stopsLevelPoints * point;

   if(stopsLevel > 0 && MathAbs(currentPrice - newSL) < stopsLevel) {
      Log(symbol + " Stops level violation (distance: " + DoubleToString(MathAbs(currentPrice - newSL), digits) +
          " < stops: " + DoubleToString(stopsLevel, digits) + ") - adjusting SL", "BE");

      // Adjust newSL to meet minimum distance requirement
      if(posType == POSITION_TYPE_BUY) {
         newSL = NormalizeDouble(currentPrice - stopsLevel - point, digits);
      } else {
         newSL = NormalizeDouble(currentPrice + stopsLevel + point, digits);
      }

      // Re-verify it's still better than current SL
      if((posType == POSITION_TYPE_BUY && newSL <= currentSL) ||
         (posType == POSITION_TYPE_SELL && newSL >= currentSL)) {
         Log(symbol + " Adjusted SL (" + DoubleToString(newSL, digits) +
             ") still not better than current SL (" + DoubleToString(currentSL, digits) + ") - skipping", "BE");
         return false;
      }
   }

   // Debug logging for breakeven calculation
   Log(symbol + " BE Attempt: Entry=" + DoubleToString(entryPrice, digits) +
       " | Buffer=" + DoubleToString(buffer, digits) + " (" + IntegerToString(BreakevenBufferPips) + " pips)" +
       " | NewSL=" + DoubleToString(newSL, digits) +
       " | CurrentSL=" + DoubleToString(currentSL, digits) +
       " | Price=" + DoubleToString(currentPrice, digits) +
       " | StopsLevel=" + DoubleToString(stopsLevel, digits), "DEBUG");

   // Modify position with retry logic
   int maxRetries = 3;
   for(int retry = 0; retry < maxRetries; retry++) {
      ResetLastError();
      if(trade.PositionModify(ticket, newSL, currentTP)) {
         Log(">>> BREAKEVEN SET <<< " + symbol + " Ticket: " + IntegerToString(ticket) +
             " | Entry: " + DoubleToString(entryPrice, digits) +
             " | New SL: " + DoubleToString(newSL, digits) +
             " | Buffer: " + IntegerToString(BreakevenBufferPips) + " pips", "BREAKEVEN");
         return true;
      }

      int error = GetLastError();
      Log(symbol + " Breakeven attempt " + IntegerToString(retry + 1) + "/" + IntegerToString(maxRetries) +
          " failed: Error " + IntegerToString(error) + " - " + trade.ResultRetcodeDescription(), "ERROR");

      // Specific error logging for common issues
      if(error == 10013) {
         Log(symbol + " INVALID_STOPS: NewSL=" + DoubleToString(newSL, digits) +
             " | Price=" + DoubleToString(currentPrice, digits) +
             " | Distance=" + DoubleToString(MathAbs(currentPrice - newSL), digits) +
             " | StopsLevel=" + DoubleToString(stopsLevel, digits) +
             " | Check SYMBOL_TRADE_STOPS_LEVEL requirements", "ERROR");
      }

      // Don't retry on certain terminal errors
      if(error == 10009 || error == 10013 || error == 10014 || error == 10015 ||
         error == 10016 || error == 10020 || error == 4756) {
         // 10009=DONE, 10013=INVALID_STOPS, 10014=INVALID_VOLUME, 10015=INVALID_PRICE
         // 10016=REJECT, 10020=POSITION_CLOSED, 4756=TRADE_MODIFY_DENIED
         break;
      }

      Sleep(100);  // Brief pause before retry
   }

   return false;
}

//+------------------------------------------------------------------+
//| Process Symbol                                                   |
//+------------------------------------------------------------------+
void ProcessSymbol(int symbolIndex) {
   if(!g_symbols[symbolIndex].enabled) return;

   // NOTE: MonitorTrades() is now called once per tick per symbol in OnTimer (24/7),
   // before the session gates - so it has already run this tick. Just re-read the state.
   SIGNAL_STATE state = g_symbols[symbolIndex].signalState;

   if(state != STATE_WAITING_H1_SIGNAL && state != STATE_SIGNAL_COMPLETE) {
      if(ShouldResetSignal(symbolIndex)) {
         Log(g_symbols[symbolIndex].name + " Signal RESET - Timeout or invalidated", "RESET");
         ResetSymbolState(symbolIndex);
         return;
      }
   }

   state = g_symbols[symbolIndex].signalState;

   switch(state) {
      case STATE_WAITING_H1_SIGNAL:
         CheckH1Signal(symbolIndex);
         break;

      case STATE_WAITING_M5_RETEST:
      case STATE_WAITING_M5_RETEST2:
         CheckM5Retest(symbolIndex);
         break;

      case STATE_WAITING_M5_ENGULFING:
         CheckM5Engulfing(symbolIndex);
         break;

      case STATE_BATCH1_ACTIVE:
      case STATE_BATCH2_ACTIVE:
      case STATE_SIGNAL_COMPLETE:
         break;
   }
}

//+------------------------------------------------------------------+
//| Check if Signal Should Be Reset                                  |
//+------------------------------------------------------------------+
bool ShouldResetSignal(int symbolIndex) {
   string symbol = g_symbols[symbolIndex].name;
   SIGNAL_STATE state = g_symbols[symbolIndex].signalState;

   // Failsafe for stuck batch states
   if(state == STATE_BATCH1_ACTIVE || state == STATE_BATCH2_ACTIVE) {
      bool hasOpenTrades = g_symbols[symbolIndex].trade1_1.isOpen ||
                           g_symbols[symbolIndex].trade1_2.isOpen ||
                           g_symbols[symbolIndex].trade2_1.isOpen ||
                           g_symbols[symbolIndex].trade2_2.isOpen;

      if(!hasOpenTrades) {
         bool hasRealPositions = false;
         for(int p = PositionsTotal() - 1; p >= 0; p--) {
            if(PositionSelectByTicket(PositionGetTicket(p))) {
               if(PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
                  PositionGetString(POSITION_SYMBOL) == symbol) {
                  hasRealPositions = true;
                  break;
               }
            }
         }

         if(!hasRealPositions) {
            return true;
         }
      }
   }

   if(state != STATE_WAITING_M5_RETEST &&
      state != STATE_WAITING_M5_ENGULFING &&
      state != STATE_WAITING_M5_RETEST2) {
      return false;
   }

   if(SignalTimeoutHours > 0 && g_symbols[symbolIndex].h1SignalTime > 0) {
      int hoursElapsed = (int)((TimeCurrent() - g_symbols[symbolIndex].h1SignalTime) / 3600);
      if(hoursElapsed >= SignalTimeoutHours) {
         return true;
      }
   }

   if(ResetOnNewH1Bar && g_symbols[symbolIndex].h1SignalTime > 0) {
      int barsSinceSignal = iBarShift(symbol, HTF_TIMEFRAME, g_symbols[symbolIndex].h1SignalTime);
      if(barsSinceSignal >= 2) {
         return true;
      }
   }

   return false;
}

//+------------------------------------------------------------------+
//| Check Daily Reset                                                |
//+------------------------------------------------------------------+
void CheckDailyReset() {
   MqlDateTime dt, resetDt;
   TimeToStruct(TimeCurrent(), dt);
   TimeToStruct(g_dailyResetTime, resetDt);

   if(resetDt.day_of_year != dt.day_of_year || resetDt.year != dt.year) {
      g_dailyTrades = 0;
      g_dailyResetTime = TimeCurrent();
      g_dailyStartBalance = account.Balance();
      g_dailyPnL = 0;
      g_dailyLossLimitHit = false;

      for(int i = 0; i < MAX_SYMBOLS; i++) {
         if(!g_symbols[i].enabled) continue;

         // Reset per-symbol trade counter
         g_symbols[i].dailyTrades = 0;

         if(g_symbols[i].signalState != STATE_WAITING_H1_SIGNAL) {
            bool hasOpenPositions = false;
            for(int p = PositionsTotal() - 1; p >= 0; p--) {
               if(PositionSelectByTicket(PositionGetTicket(p))) {
                  if(PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
                     PositionGetString(POSITION_SYMBOL) == g_symbols[i].name) {
                     hasOpenPositions = true;
                     break;
                  }
               }
            }

            if(!hasOpenPositions) {
               ResetSymbolState(i);
            }
         }
      }

      Log("=== DAILY RESET === Balance: $" + DoubleToString(g_dailyStartBalance, 2), "RESET");
   }
}

//+------------------------------------------------------------------+
//| Check Daily Limits                                               |
//+------------------------------------------------------------------+
bool CheckDailyLimits() {
   g_dailyPnL = account.Balance() - g_dailyStartBalance;

   if(MaxDailyLossPercent > 0) {
      double maxLoss = g_dailyStartBalance * (MaxDailyLossPercent / 100.0);
      if(g_dailyPnL <= -maxLoss) {
         if(!g_dailyLossLimitHit) {
            g_dailyLossLimitHit = true;
            Log("!!! DAILY LOSS LIMIT HIT: $" + DoubleToString(g_dailyPnL, 2), "LIMIT");
         }
         return false;
      }
   }

   if(DailyProfitTarget > 0 && g_dailyPnL >= DailyProfitTarget) return false;

   if(MaxTradesPerDay > 0) {
      if(g_dailyTrades >= MaxTradesPerDay) return false;
      // Warn when approaching limit (2 trades = 1 batch remaining)
      if(g_dailyTrades >= MaxTradesPerDay - 2 && g_dailyTrades > 0) {
         static datetime lastLimitWarn = 0;
         if(TimeCurrent() - lastLimitWarn > 3600) {  // Log once per hour max
            Log("Approaching daily trade limit: " + IntegerToString(g_dailyTrades) +
                "/" + IntegerToString(MaxTradesPerDay) + " trades", "LIMIT");
            lastLimitWarn = TimeCurrent();
         }
      }
   }

   return true;
}

//+------------------------------------------------------------------+
//| Check Per-Symbol Daily Trade Limit                               |
//+------------------------------------------------------------------+
bool CheckSymbolTradeLimit(int symbolIndex) {
   // Check per-symbol limit
   if(g_symbols[symbolIndex].maxTradesPerDay > 0 &&
      g_symbols[symbolIndex].dailyTrades >= g_symbols[symbolIndex].maxTradesPerDay) {
      return false;  // Limit reached for this symbol
   }
   return true;  // OK to trade
}

//+------------------------------------------------------------------+
//| Apply a live open position to the matching trade slot             |
//| Fills ticket/positionId/entry/sl/tp/lots and marks isOpen.        |
//+------------------------------------------------------------------+
void ApplyLivePositionToSlot(TradeInfo &t, ulong posTicket) {
   t.ticket     = posTicket;
   t.positionId = (ulong)PositionGetInteger(POSITION_IDENTIFIER);
   t.entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   t.sl         = PositionGetDouble(POSITION_SL);
   t.tp         = PositionGetDouble(POSITION_TP);
   t.lots       = PositionGetDouble(POSITION_VOLUME);
   t.isOpen     = true;
   if(t.openTime == 0) t.openTime = (datetime)PositionGetInteger(POSITION_TIME);
}

//+------------------------------------------------------------------+
//| Restart-Safe Tracking: Rebuild one symbol's state from positions  |
//| Called on OnInit when a symbol would start fresh. Scans positions |
//| (magic + symbol), matches by comment FX_B{n}_T{1|2}, restores     |
//| persisted notify flags, and resumes BATCH_ACTIVE.                 |
//+------------------------------------------------------------------+
bool RebuildSymbolFromPositions(int symbolIndex) {
   if(g_isOptimization || g_isTester) return false;
   string symbol = g_symbols[symbolIndex].name;

   // Restore persisted flags first (authoritative for notified/hitTP/breakeven)
   bool hadPersist = HasPersistedState(symbolIndex);
   if(hadPersist) {
      g_symbols[symbolIndex].signalState  = (SIGNAL_STATE)(int)GlobalVariableGet(PersistKey(symbolIndex, "state"));
      g_symbols[symbolIndex].batchCount   = (int)GlobalVariableGet(PersistKey(symbolIndex, "batch"));
      g_symbols[symbolIndex].h1Direction  = (TREND_STATE)(int)GlobalVariableGet(PersistKey(symbolIndex, "dir"));
      g_symbols[symbolIndex].h1EngulfType = (ENGULF_TYPE)(int)GlobalVariableGet(PersistKey(symbolIndex, "engulf"));
      g_symbols[symbolIndex].h1SignalTime = (datetime)(long)GlobalVariableGet(PersistKey(symbolIndex, "h1time"));
      LoadTradeSlot(symbolIndex, "t11", g_symbols[symbolIndex].trade1_1);
      LoadTradeSlot(symbolIndex, "t12", g_symbols[symbolIndex].trade1_2);
      LoadTradeSlot(symbolIndex, "t21", g_symbols[symbolIndex].trade2_1);
      LoadTradeSlot(symbolIndex, "t22", g_symbols[symbolIndex].trade2_2);
   }

   // Reconcile with live positions: mark slots open by what really exists
   int matched = 0;
   for(int p = PositionsTotal() - 1; p >= 0; p--) {
      ulong posTicket = PositionGetTicket(p);
      if(!PositionSelectByTicket(posTicket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;

      string comment = PositionGetString(POSITION_COMMENT);
      // Comments stamped at entry: FX_B{batch}_T{1|2}_{dir}
      bool isBatch1 = (StringFind(comment, "_B1_") >= 0);
      bool isBatch2 = (StringFind(comment, "_B2_") >= 0);
      bool isT1 = (StringFind(comment, "_T1_") >= 0);
      bool isT2 = (StringFind(comment, "_T2_") >= 0);

      if(isBatch1 && isT1)      ApplyLivePositionToSlot(g_symbols[symbolIndex].trade1_1, posTicket);
      else if(isBatch1 && isT2) ApplyLivePositionToSlot(g_symbols[symbolIndex].trade1_2, posTicket);
      else if(isBatch2 && isT1) ApplyLivePositionToSlot(g_symbols[symbolIndex].trade2_1, posTicket);
      else if(isBatch2 && isT2) ApplyLivePositionToSlot(g_symbols[symbolIndex].trade2_2, posTicket);
      else continue;
      matched++;
   }

   if(matched == 0 && !hadPersist) return false;

   if(matched == 0) {
      // No live positions remain - signal effectively complete; clear and start fresh
      ClearPersistedState(symbolIndex);
      g_symbols[symbolIndex].signalState = STATE_WAITING_H1_SIGNAL;
      g_symbols[symbolIndex].batchCount = 0;
      ZeroMemory(g_symbols[symbolIndex].trade1_1); ZeroMemory(g_symbols[symbolIndex].trade1_2);
      ZeroMemory(g_symbols[symbolIndex].trade2_1); ZeroMemory(g_symbols[symbolIndex].trade2_2);
      return false;
   }

   // Resume monitoring in the correct active state
   SIGNAL_STATE st = g_symbols[symbolIndex].signalState;
   if(st != STATE_BATCH1_ACTIVE && st != STATE_BATCH2_ACTIVE) {
      if(g_symbols[symbolIndex].trade2_1.isOpen || g_symbols[symbolIndex].trade2_2.isOpen ||
         g_symbols[symbolIndex].batchCount >= 2) {
         g_symbols[symbolIndex].signalState = STATE_BATCH2_ACTIVE;
      } else {
         g_symbols[symbolIndex].signalState = STATE_BATCH1_ACTIVE;
         if(g_symbols[symbolIndex].batchCount < 1) g_symbols[symbolIndex].batchCount = 1;
      }
   }

   Log(symbol + " RESTART RECOVERY: resumed " + GetStateName(g_symbols[symbolIndex].signalState) +
       " | matched " + IntegerToString(matched) + " live position(s) | batch=" +
       IntegerToString(g_symbols[symbolIndex].batchCount), "RECOVERY");

   PersistState(symbolIndex);
   return true;
}

//+------------------------------------------------------------------+
//| Expert Initialization                                            |
//+------------------------------------------------------------------+
int OnInit() {
   g_isTester = MQLInfoInteger(MQL_TESTER);
   g_isOptimization = MQLInfoInteger(MQL_OPTIMIZATION);

   Log("========================================", "INIT");
   Log("FOREX ENGULFING BOT v1.1 Starting", "INIT");
   Log("NEW: EMA Trend Direction Filter Enabled", "INIT");
   Log("Symbols: GBPUSD, GBPJPY", "INIT");
   Log("Strategy: H1 Engulfing (must match EMA trend) -> M5 Retest (EMA aligned) -> Dual Trade", "INIT");

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(30);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   g_activeSymbols = 0;
   g_symbolEnabled[0] = TradeGBPUSD;
   g_symbolEnabled[1] = TradeGBPJPY;
   g_maxSpreads[0] = MaxSpread_GBPUSD;
   g_maxSpreads[1] = MaxSpread_GBPJPY;

   for(int i = 0; i < MAX_SYMBOLS; i++) {
      if(!InitSymbolConfig(i, g_symbolNames[i], g_symbolEnabled[i], g_maxSpreads[i])) {
         Log("Failed to initialize " + g_symbolNames[i], "ERROR");
      }
   }

   if(g_activeSymbols == 0) {
      Alert("No symbols initialized!");
      return INIT_FAILED;
   }

   g_testStartTime = TimeCurrent();
   g_initialBalance = account.Balance();
   g_peakBalance = g_initialBalance;
   g_dailyResetTime = TimeCurrent();
   g_dailyStartBalance = account.Balance();

   // Restart-safe tracking: resume monitoring any open positions per symbol
   for(int i = 0; i < MAX_SYMBOLS; i++) {
      if(!g_symbols[i].enabled) continue;
      if(RebuildSymbolFromPositions(i)) {
         Log(g_symbols[i].name + " Resumed tracking after restart - monitoring existing positions", "INIT");
      }
   }

   EventSetMillisecondTimer(TimerIntervalMs);

   // Add visual EMAs to chart
   AddVisualEMAs();

   Log("Active Symbols: " + IntegerToString(g_activeSymbols), "INIT");
   Log("Risk: " + (UsePercentageRisk ? DoubleToString(RiskPercent, 1) + "%" : "$" + DoubleToString(RiskDollars, 2)) + " per trade", "INIT");

   // Log session settings
   Log("--- SESSION SETTINGS ---", "INIT");
   if(EnableSessionFilter) {
      Log("Session Filter: ENABLED (Broker GMT Offset: " + IntegerToString(BrokerGMTOffset) + ")", "INIT");
      Log("Asian Session: " + (TradeAsianSession ? "TRADE" : "NO TRADE") +
          " (" + IntegerToString(AsianStartHour) + ":00 - " + IntegerToString(AsianEndHour) + ":00 GMT)", "INIT");
      Log("London Session: " + (TradeLondonSession ? "TRADE" : "NO TRADE") +
          " (" + IntegerToString(LondonStartHour) + ":00 - " + IntegerToString(LondonEndHour) + ":00 GMT)", "INIT");
      Log("New York Session: " + (TradeNewYorkSession ? "TRADE" : "NO TRADE") +
          " (" + IntegerToString(NewYorkStartHour) + ":00 - " + IntegerToString(NewYorkEndHour) + ":00 GMT)", "INIT");
   } else {
      Log("Session Filter: DISABLED (Trading 24/7 - All Sessions)", "INIT");
   }

   Log("Balance: $" + DoubleToString(account.Balance(), 2), "INIT");
   Log("========================================", "INIT");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Timer Function                                                   |
//+------------------------------------------------------------------+
void OnTimer() {
   if(!g_botEnabled) return;

   CheckDailyReset();

   // Account heartbeat ping (24/7) - keeps the dashboard current between signals
   if(AccountPingMinutes > 0 &&
      (g_lastAccountPing == 0 || TimeCurrent() - g_lastAccountPing >= AccountPingMinutes * 60)) {
      g_lastAccountPing = TimeCurrent();
      SendAccountHeartbeat();
   }

   // Monitor open trades 24/7 (incl. Asian session / off-hours / daily-limit lockout) so
   // TP/BE/close detection and follow-up notifications never stall. This is the SINGLE
   // monitor call per tick - the legacy call inside ProcessSymbol was removed so
   // MonitorTrades runs exactly once per symbol regardless of session. Entries stay gated below.
   // SIGNAL_COMPLETE is included so MonitorTrades' reset tail runs (ExecuteTradeBatch can
   // set SIGNAL_COMPLETE at max batches, and that reset used to depend on ProcessSymbol).
   for(int i = 0; i < MAX_SYMBOLS; i++) {
      if(!g_symbols[i].enabled) continue;
      if(g_symbols[i].signalState == STATE_BATCH1_ACTIVE ||
         g_symbols[i].signalState == STATE_BATCH2_ACTIVE ||
         g_symbols[i].signalState == STATE_SIGNAL_COMPLETE) {
         MonitorTrades(i);
      }
   }

   if(!CheckDailyLimits()) {
      UpdateChartComment("DAILY LIMIT REACHED");
      return;
   }

   // PERMANENT BLOCK: Asian session is NEVER traded (entries only - monitoring ran above)
   if(IsAsianSession()) {
      static datetime lastAsianLog = 0;
      if(TimeCurrent() - lastAsianLog > 3600) {
         Log("ASIAN SESSION BLOCKED | GMT Hour: " + IntegerToString(GetGMTHour()) +
             " | Asian hours: " + IntegerToString(AsianStartHour) + ":00-" +
             IntegerToString(AsianEndHour) + ":00 GMT", "SESSION");
         lastAsianLog = TimeCurrent();
      }
      UpdateChartComment("ASIAN SESSION - NO TRADING");
      return;
   }

   if(!IsTradingAllowedInSession()) {
      UpdateChartComment("SESSION FILTER - OFF HOURS");
      return;
   }

   for(int i = 0; i < MAX_SYMBOLS; i++) {
      ProcessSymbol(i);
   }

   UpdateChartComment("");
}

//+------------------------------------------------------------------+
//| Build Status String for a Single Symbol                          |
//+------------------------------------------------------------------+
string BuildSymbolStatus(int i, string extraStatus = "") {
   string status = "";
   status += "=== FOREX ENGULFING BOT v1.1 ===\n";
   status += "Symbol: " + g_symbols[i].name + "\n";
   status += "Trades: " + IntegerToString(g_symbols[i].dailyTrades);
   if(g_symbols[i].maxTradesPerDay > 0) {
      status += "/" + IntegerToString(g_symbols[i].maxTradesPerDay);
   }
   status += " | Total: " + IntegerToString(g_dailyTrades) + " | P/L: $" + DoubleToString(g_dailyPnL, 2) + "\n";
   status += "Auto-Breakeven: " + (AutoBreakeven ? "ON" : "OFF") + "\n\n";

   status += "State: " + GetStateName(g_symbols[i].signalState) + "\n";
   status += "Batch: " + IntegerToString(g_symbols[i].batchCount) + "/" + IntegerToString(MaxBatchesPerH1Signal) + "\n";
   status += "Signal Direction: " + (g_symbols[i].h1Direction == TREND_BULLISH ? "BULLISH" : (g_symbols[i].h1Direction == TREND_BEARISH ? "BEARISH" : "NONE")) + "\n";

   TREND_STATE h1EmaTrend = GetEMATrend(g_symbols[i].emaFastHandle[TF_H1], g_symbols[i].emaSlowHandle[TF_H1], 0);
   TREND_STATE m5EmaTrend = GetEMATrend(g_symbols[i].emaFastHandle[TF_M5], g_symbols[i].emaSlowHandle[TF_M5], 0);
   status += "H1 EMA: " + GetTrendName(h1EmaTrend) + " | M5 EMA: " + GetTrendName(m5EmaTrend);

   if(g_symbols[i].h1Direction != TREND_NONE) {
      bool aligned = (m5EmaTrend == g_symbols[i].h1Direction);
      status += " (" + (aligned ? "ALIGNED" : "MISALIGNED") + ")";
   }
   status += "\n";

   status += "Spread: " + DoubleToString(g_symbols[i].calc.GetSpreadPips(), 1) + " pips\n";

   status += "H1 Bars: " + IntegerToString(g_symbols[i].h1BarsAnalyzed);
   if(g_symbols[i].lastH1BarCheck > 0) {
      int secsAgo = (int)(TimeCurrent() - g_symbols[i].lastH1BarCheck);
      status += " (" + IntegerToString(secsAgo / 60) + "m " + IntegerToString(secsAgo % 60) + "s ago)";
   }
   status += "\n";
   status += "H1 Result: " + g_symbols[i].lastH1Result + "\n";

   status += "M5 Bars: " + IntegerToString(g_symbols[i].m5BarsAnalyzed);
   if(g_symbols[i].lastM5BarCheck > 0) {
      int secsAgo = (int)(TimeCurrent() - g_symbols[i].lastM5BarCheck);
      status += " (" + IntegerToString(secsAgo / 60) + "m " + IntegerToString(secsAgo % 60) + "s ago)";
   }
   status += "\n";
   if(g_symbols[i].signalState != STATE_WAITING_H1_SIGNAL) {
      status += "M5 Result: " + g_symbols[i].lastM5Result + "\n";
   }

   if(extraStatus != "") {
      status += "\n>>> " + extraStatus + " <<<";
   }

   status += "\nLast Update: " + TimeToString(TimeCurrent(), TIME_SECONDS);
   return status;
}

//+------------------------------------------------------------------+
//| Update Chart Comment (Visual Status Display)                     |
//+------------------------------------------------------------------+
void UpdateChartComment(string extraStatus = "") {
   // Build combined status for main chart (shows all symbols)
   string mainStatus = "";
   mainStatus += "=== FOREX ENGULFING BOT v1.1 (EMA Trend Filter) ===\n";
   mainStatus += "Daily Trades: " + IntegerToString(g_dailyTrades) + "\n";
   mainStatus += "Daily P/L: $" + DoubleToString(g_dailyPnL, 2) + "\n";
   mainStatus += "Auto-Breakeven: " + (AutoBreakeven ? "ON" : "OFF") + "\n\n";

   for(int i = 0; i < MAX_SYMBOLS; i++) {
      if(!g_symbols[i].enabled) continue;

      mainStatus += "--- " + g_symbols[i].name + " ---\n";
      mainStatus += "Trades: " + IntegerToString(g_symbols[i].dailyTrades);
      if(g_symbols[i].maxTradesPerDay > 0) {
         mainStatus += "/" + IntegerToString(g_symbols[i].maxTradesPerDay);
      }
      mainStatus += "\n";
      mainStatus += "State: " + GetStateName(g_symbols[i].signalState) + "\n";
      mainStatus += "Batch: " + IntegerToString(g_symbols[i].batchCount) + "/" + IntegerToString(MaxBatchesPerH1Signal) + "\n";
      mainStatus += "Signal: " + (g_symbols[i].h1Direction == TREND_BULLISH ? "BULLISH" : (g_symbols[i].h1Direction == TREND_BEARISH ? "BEARISH" : "NONE")) + "\n";

      TREND_STATE h1EmaTrend = GetEMATrend(g_symbols[i].emaFastHandle[TF_H1], g_symbols[i].emaSlowHandle[TF_H1], 0);
      TREND_STATE m5EmaTrend = GetEMATrend(g_symbols[i].emaFastHandle[TF_M5], g_symbols[i].emaSlowHandle[TF_M5], 0);
      mainStatus += "H1: " + GetTrendName(h1EmaTrend) + " | M5: " + GetTrendName(m5EmaTrend);

      if(g_symbols[i].h1Direction != TREND_NONE) {
         bool aligned = (m5EmaTrend == g_symbols[i].h1Direction);
         mainStatus += " (" + (aligned ? "OK" : "X") + ")";
      }
      mainStatus += "\n";

      mainStatus += "H1 Result: " + g_symbols[i].lastH1Result + "\n";
      if(g_symbols[i].signalState != STATE_WAITING_H1_SIGNAL) {
         mainStatus += "M5 Result: " + g_symbols[i].lastM5Result + "\n";
      }
      mainStatus += "\n";
   }

   if(extraStatus != "") {
      mainStatus += ">>> " + extraStatus + " <<<\n";
   }

   mainStatus += "Last Update: " + TimeToString(TimeCurrent(), TIME_SECONDS);

   // Update main chart comment
   Comment(mainStatus);

   // Update individual symbol charts with their own status
   for(int i = 0; i < MAX_SYMBOLS; i++) {
      if(!g_symbols[i].enabled) continue;

      long chartId = FindChartBySymbol(g_symbols[i].name);
      if(chartId != -1 && chartId != ChartID()) {
         // Update the other symbol's chart with its specific status
         string symbolStatus = BuildSymbolStatus(i, extraStatus);
         ChartSetString(chartId, CHART_COMMENT, symbolStatus);
      }
   }
}

//+------------------------------------------------------------------+
//| Tick Function                                                    |
//+------------------------------------------------------------------+
void OnTick() {
   // Timer handles main logic
}

//+------------------------------------------------------------------+
//| Expert Deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   EventKillTimer();

   g_testEndTime = TimeCurrent();

   PrintTradeStatistics();

   for(int i = 0; i < MAX_SYMBOLS; i++) {
      if(g_symbols[i].enabled) {
         if(g_symbols[i].emaFastHandle[TF_H1] != INVALID_HANDLE)
            IndicatorRelease(g_symbols[i].emaFastHandle[TF_H1]);
         if(g_symbols[i].emaSlowHandle[TF_H1] != INVALID_HANDLE)
            IndicatorRelease(g_symbols[i].emaSlowHandle[TF_H1]);
         if(g_symbols[i].emaFastHandle[TF_M5] != INVALID_HANDLE)
            IndicatorRelease(g_symbols[i].emaFastHandle[TF_M5]);
         if(g_symbols[i].emaSlowHandle[TF_M5] != INVALID_HANDLE)
            IndicatorRelease(g_symbols[i].emaSlowHandle[TF_M5]);
         if(g_symbols[i].atrHandle[TF_H1] != INVALID_HANDLE)
            IndicatorRelease(g_symbols[i].atrHandle[TF_H1]);
         if(g_symbols[i].atrHandle[TF_M5] != INVALID_HANDLE)
            IndicatorRelease(g_symbols[i].atrHandle[TF_M5]);
      }
   }

   Comment("");  // Clear chart comment

   // Remove visual EMAs from chart
   RemoveVisualEMAs();

   Log("Bot stopped. Daily trades: " + IntegerToString(g_dailyTrades), "DEINIT");
}

//+------------------------------------------------------------------+
//| Print Trade Statistics                                           |
//+------------------------------------------------------------------+
void PrintTradeStatistics() {
   double finalBalance = AccountInfoDouble(ACCOUNT_BALANCE);

   // Calculate totals
   int totalTrades = 0;
   int totalWins = 0;
   int totalLosses = 0;
   double totalProfit = 0;
   double totalGrossProfit = 0;
   double totalGrossLoss = 0;
   int totalH1Signals = 0;

   for(int i = 0; i < MAX_SYMBOLS; i++) {
      if(!g_symbols[i].enabled) continue;
      totalTrades += g_symbols[i].stats.totalTrades;
      totalWins += g_symbols[i].stats.wins;
      totalLosses += g_symbols[i].stats.losses;
      totalProfit += g_symbols[i].stats.netProfit;
      totalGrossProfit += g_symbols[i].stats.grossProfit;
      totalGrossLoss += g_symbols[i].stats.grossLoss;
      totalH1Signals += g_symbols[i].stats.h1SignalsDetected;
   }

   double overallWinRate = totalTrades > 0 ? (double)totalWins / totalTrades * 100.0 : 0;
   double overallPF = MathAbs(totalGrossLoss) > 0.01 ? totalGrossProfit / MathAbs(totalGrossLoss) : 0;
   double returnPct = g_initialBalance > 0 ? (totalProfit / g_initialBalance) * 100.0 : 0;
   double ddPct = g_peakBalance > 0 ? (g_maxDrawdown / g_peakBalance) * 100.0 : 0;

   Print("");
   Print("================================================================================");
   Print("                    FOREX ENGULFING BOT v1.0 - TRADE REPORT                     ");
   Print("================================================================================");
   Print("");

   Print("TEST PERIOD");
   Print("  Start:           ", TimeToString(g_testStartTime, TIME_DATE|TIME_MINUTES));
   Print("  End:             ", TimeToString(g_testEndTime, TIME_DATE|TIME_MINUTES));
   Print("");

   Print("ACCOUNT SUMMARY");
   Print("  Initial Balance: $", DoubleToString(g_initialBalance, 2));
   Print("  Final Balance:   $", DoubleToString(finalBalance, 2));
   Print("  Net Change:      $", DoubleToString(totalProfit, 2), " (", DoubleToString(returnPct, 2), "%)");
   Print("");

   Print("--------------------------------------------------------------------------------");
   Print("                           PERFORMANCE SUMMARY                                  ");
   Print("--------------------------------------------------------------------------------");
   Print("  Total Net Profit:    $", DoubleToString(totalProfit, 2));
   Print("  Gross Profit:        $", DoubleToString(totalGrossProfit, 2));
   Print("  Gross Loss:          $", DoubleToString(MathAbs(totalGrossLoss), 2));
   Print("  Profit Factor:       ", DoubleToString(overallPF, 2));
   Print("  Max Drawdown:        $", DoubleToString(g_maxDrawdown, 2), " (", DoubleToString(ddPct, 2), "%)");
   Print("");

   Print("--------------------------------------------------------------------------------");
   Print("                           TRADE STATISTICS                                     ");
   Print("--------------------------------------------------------------------------------");
   Print("  Total Trades:        ", IntegerToString(totalTrades));
   Print("  Winning Trades:      ", IntegerToString(totalWins), " (", DoubleToString(overallWinRate, 2), "%)");
   Print("  Losing Trades:       ", IntegerToString(totalLosses));
   Print("  H1 Signals Detected: ", IntegerToString(totalH1Signals));
   Print("");

   Print("--------------------------------------------------------------------------------");
   Print("                           PER-SYMBOL BREAKDOWN                                 ");
   Print("--------------------------------------------------------------------------------");

   for(int i = 0; i < MAX_SYMBOLS; i++) {
      if(!g_symbols[i].enabled) continue;

      SymbolStats stats = g_symbols[i].stats;

      Print("  ", g_symbols[i].name, ":");
      Print("    Trades: ", IntegerToString(stats.totalTrades),
            " | Wins: ", IntegerToString(stats.wins),
            " | Win Rate: ", DoubleToString(stats.WinRate(), 1), "%");
      Print("    Net P/L: $", DoubleToString(stats.netProfit, 2),
            " | Gross Profit: $", DoubleToString(stats.grossProfit, 2),
            " | Gross Loss: $", DoubleToString(MathAbs(stats.grossLoss), 2));
      Print("    PF: ", DoubleToString(stats.ProfitFactor(), 2),
            " | Expectancy: $", DoubleToString(stats.Expectancy(), 2));
      Print("    H1 Signals: ", IntegerToString(stats.h1SignalsDetected),
            " | Batch1: ", IntegerToString(stats.batch1Trades),
            " | Batch2: ", IntegerToString(stats.batch2Trades),
            " | Fib Rejected: ", IntegerToString(stats.fibRejections));
      Print("");
   }

   Print("================================================================================");
   Print("");
}
//+------------------------------------------------------------------+
