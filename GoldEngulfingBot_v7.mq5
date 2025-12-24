//+------------------------------------------------------------------+
//|                                         GoldEngulfingBot_v7.mq5  |
//|                        EMA Crossover & Retest Gold-Only EA       |
//|                                                       Version 7.0|
//|                    SIGNAL BROADCAST MODE - For Multi-Account Use |
//|  Supports: XAUUSD (Gold) ONLY                                    |
//|  Strategy: H1 Engulfing + EMA -> M5 Retest + Engulfing -> Entry  |
//|  Features: Dual Trade (1:1 + 1:2 RR), ATR-based SL, 2 Batches    |
//+------------------------------------------------------------------+
#property copyright "FXBot Trading"
#property link      "https://fxbot.trading"
#property version   "7.00"
#property strict
#property description "Gold-Only EMA 10/23 Engulfing Strategy v7.0"
#property description "H1: Engulfing candle closes above/below EMA lines"
#property description "M5: Wait for EMA retest + Engulfing confirmation"
#property description "Entry: Dual trades (1:1 RR + 1:2 RR)"
#property description "Max 2 batches per H1 signal"

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
input int      MagicNumber = 247891;                      // Magic Number
input bool     EnableServerConnection = true;             // Connect to server
input int      HeartbeatIntervalSec = 30;                 // Heartbeat interval (seconds)

input group "=== EMA Settings ==="
input int      EMA_Fast_Period = 10;                      // Fast EMA Period
input int      EMA_Slow_Period = 23;                      // Slow EMA Period
input ENUM_APPLIED_PRICE EMA_Price = PRICE_CLOSE;         // EMA Applied Price

input group "=== Timeframe Settings ==="
input ENUM_TIMEFRAMES HTF_Timeframe = PERIOD_H1;          // Higher Timeframe (H1 Signal Detection)
input ENUM_TIMEFRAMES LTF_Timeframe = PERIOD_M5;          // Lower Timeframe (M5 Entry Confirmation)

input group "=== Risk Management ==="
input bool     UsePercentageRisk = true;                  // TRUE = % of balance | FALSE = Fixed $
input double   RiskPercent = 1.0;                         // Risk per trade (each of the 2 trades)
input double   RiskDollars = 100.0;                       // Fixed dollar risk per trade
input double   MinRiskPercent = 1.0;                      // MINIMUM risk % floor
input double   MaxRiskPercent = 5.0;                      // MAXIMUM risk % ceiling
input double   RR_Trade1 = 1.0;                           // Risk:Reward for Trade 1
input double   RR_Trade2 = 2.0;                           // Risk:Reward for Trade 2

input group "=== ATR Stop Loss Settings ==="
input int      ATR_Period = 14;                           // ATR Period for SL calculation
input double   ATR_Multiplier = 1.5;                      // ATR Multiplier for SL
input int      SpreadBufferPips = 3;                      // Additional spread buffer (pips)
input int      MinSLPips = 10;                            // Minimum SL (pips)
input int      MaxSLPips = 100;                           // Maximum SL (pips)

input group "=== Gold Settings ==="
input double   MaxSpread_XAUUSD = 15.0;                   // Max spread for Gold (pips)

input group "=== Trade Batch Settings ==="
input int      MaxBatchesPerH1Signal = 2;                 // Max trade batches per H1 signal
input int      SignalTimeoutHours = 4;                    // Reset signal if no trade within X hours (0=disabled)
input bool     ResetOnNewH1Bar = true;                    // Reset if new H1 bar and no trades taken
input bool     ResetOnOppositeSignal = true;              // Reset if opposite H1 engulfing detected

input group "=== Position Limits ==="
input int      MaxPositionsPerSymbol = 10;                // Max positions per symbol
input int      MaxTotalPositions = 20;                    // Max total open positions
input double   MarginBufferPercent = 10.0;                // Margin safety buffer %

input group "=== Trading Sessions ==="
input bool     EnableSessionFilter = false;               // Enable session filter (FALSE = 24/7)
input int      BrokerGMTOffset = 2;                       // Broker GMT offset

input group "=== Asian Session ==="
input bool     TradeAsianSession = true;                  // Trade during Asian session
input int      AsianStartHour = 0;                        // Asian session start (GMT)
input int      AsianEndHour = 9;                          // Asian session end (GMT)

input group "=== London Session ==="
input bool     TradeLondonSession = true;                 // Trade during London session
input int      LondonStartHour = 7;                       // London session start (GMT)
input int      LondonEndHour = 16;                        // London session end (GMT)

input group "=== New York Session ==="
input bool     TradeNewYorkSession = true;                // Trade during New York session
input int      NewYorkStartHour = 13;                     // New York session start (GMT)
input int      NewYorkEndHour = 22;                       // New York session end (GMT)

input group "=== Daily Limits ==="
input int      MaxTradesPerDay = 0;                       // Max trades per day (0 = unlimited)
input double   MaxDailyLossPercent = 10.0;                // Max daily loss %
input double   DailyProfitTarget = 0;                     // Daily profit target $ (0 = disabled)

input group "=== Debug ==="
input bool     EnableLogs = true;                         // Enable debug logging
input bool     VerboseLogs = false;                       // Extra verbose logging
input int      TimerIntervalMs = 500;                     // Timer interval (ms)

//+------------------------------------------------------------------+
//| Constants and Enums                                              |
//+------------------------------------------------------------------+
#define TF_H1 0
#define TF_M5 1

enum TREND_STATE {
   TREND_NONE = 0,
   TREND_BULLISH = 1,
   TREND_BEARISH = -1
};

enum SIGNAL_STATE {
   STATE_WAITING_H1_SIGNAL = 0,      // Waiting for H1 engulfing signal
   STATE_WAITING_M5_RETEST = 1,      // H1 signal detected, waiting for M5 retest
   STATE_WAITING_M5_ENGULFING = 2,   // M5 retest detected, waiting for M5 engulfing
   STATE_BATCH1_ACTIVE = 3,          // First batch of trades active
   STATE_WAITING_M5_RETEST2 = 4,     // Waiting for second M5 retest (if 1:1 hit TP)
   STATE_BATCH2_ACTIVE = 5,          // Second batch of trades active
   STATE_SIGNAL_COMPLETE = 6         // Both batches done, wait for new H1 signal
};

enum ENGULF_TYPE {
   ENGULF_NONE = 0,
   ENGULF_SINGLE_BULLISH = 1,
   ENGULF_SINGLE_BEARISH = 2,
   ENGULF_DOUBLE_BULLISH = 3,
   ENGULF_DOUBLE_BEARISH = 4
};

//+------------------------------------------------------------------+
//| Gold Symbol Calculator Class                                      |
//+------------------------------------------------------------------+
class CGoldCalculator {
private:
   string      m_symbol;
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

      // Gold-specific pip size: 0.1 (10 cents)
      m_pipSize = 0.1;

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

   // Gold: 1 pip = $0.10 price move, 1 lot = 100 oz
   // So: 0.1 * 100 = $10 per pip per lot (standard)
   double GetFallbackPipValue(double lots) {
      return 10.0 * lots;
   }

   string      GetSymbol()       { return m_symbol; }
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
};

//+------------------------------------------------------------------+
//| Trade Tracking Structure                                         |
//+------------------------------------------------------------------+
struct TradeInfo {
   ulong    ticket;
   double   entryPrice;
   double   sl;
   double   tp;
   double   lots;
   double   rrRatio;
   bool     isOpen;
   bool     hitTP;
   datetime openTime;
};

//+------------------------------------------------------------------+
//| Enhanced Statistics Structure                                    |
//+------------------------------------------------------------------+
struct TradeStats {
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
   int      batch1Trades;
   int      batch2Trades;
   int      trade1_1_TPHits;      // 1:1 RR TP hits
   int      trade1_2_TPHits;      // 1:2 RR TP hits
   int      consecutiveWins;
   int      consecutiveLosses;
   int      maxConsecutiveWins;
   int      maxConsecutiveLosses;
   double   maxDrawdown;
   double   peakBalance;
   datetime testStartTime;
   datetime testEndTime;
   double   initialBalance;

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
      int totalBatch1 = batch1Trades / 2;  // Each batch has 2 trades
      if(totalBatch1 == 0) return 0;
      return (double)trade1_1_TPHits / totalBatch1 * 100.0;
   }

   double Trade1_2_HitRate() {
      int totalBatch1 = batch1Trades / 2;
      if(totalBatch1 == 0) return 0;
      return (double)trade1_2_TPHits / totalBatch1 * 100.0;
   }

   double ReturnPercent() {
      if(initialBalance <= 0) return 0;
      return (netProfit / initialBalance) * 100.0;
   }

   double DrawdownPercent() {
      if(peakBalance <= 0) return 0;
      return (maxDrawdown / peakBalance) * 100.0;
   }
};

//+------------------------------------------------------------------+
//| Global Variables                                                 |
//+------------------------------------------------------------------+
CTrade trade;
CPositionInfo position;
CAccountInfo account;

CGoldCalculator g_calc;
string g_symbol = "";
bool g_symbolEnabled = false;

// Signal State
SIGNAL_STATE g_signalState = STATE_WAITING_H1_SIGNAL;
TREND_STATE  g_h1Direction = TREND_NONE;
datetime     g_h1SignalTime = 0;
double       g_h1SignalPrice = 0;
ENGULF_TYPE  g_h1EngulfType = ENGULF_NONE;

// M5 Tracking
bool         g_m5RetestDetected = false;
datetime     g_m5RetestTime = 0;
bool         g_m5EngulfDetected = false;

// Batch Tracking
int          g_batchCount = 0;
TradeInfo    g_trade1_1;    // Batch 1, Trade 1 (1:1 RR)
TradeInfo    g_trade1_2;    // Batch 1, Trade 2 (1:2 RR)
TradeInfo    g_trade2_1;    // Batch 2, Trade 1 (1:1 RR)
TradeInfo    g_trade2_2;    // Batch 2, Trade 2 (1:2 RR)

// Indicator handles
int g_emaFastHandle[2];
int g_emaSlowHandle[2];
int g_atrHandle[2];

// Bar tracking
datetime g_lastBarTime[2];

// Statistics
TradeStats g_stats;

// Daily tracking
int g_dailyTrades = 0;
datetime g_dailyResetTime = 0;
double g_dailyStartBalance = 0;
double g_dailyPnL = 0;
bool g_dailyLossLimitHit = false;
bool g_botEnabled = true;

// Server connection
datetime g_lastHeartbeat = 0;

// Tester
bool g_isTester = false;
bool g_isOptimization = false;

// Activity tracking (for visual feedback)
datetime g_lastH1BarCheck = 0;
datetime g_lastM5BarCheck = 0;
int g_h1BarsAnalyzed = 0;
int g_m5BarsAnalyzed = 0;
string g_lastH1Result = "Waiting...";
string g_lastM5Result = "Waiting...";

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
//| Get Current Session Name                                         |
//+------------------------------------------------------------------+
string GetCurrentSessionName() {
   int gmtHour = GetGMTHour();
   string sessions = "";

   if(IsHourInSession(gmtHour, AsianStartHour, AsianEndHour)) {
      sessions += "ASIAN ";
   }
   if(IsHourInSession(gmtHour, LondonStartHour, LondonEndHour)) {
      sessions += "LONDON ";
   }
   if(IsHourInSession(gmtHour, NewYorkStartHour, NewYorkEndHour)) {
      sessions += "NEW_YORK ";
   }

   if(StringLen(sessions) == 0) sessions = "OFF_HOURS";

   return sessions;
}

//+------------------------------------------------------------------+
//| Check if Trading Allowed in Current Session                      |
//+------------------------------------------------------------------+
bool IsTradingAllowedInSession() {
   if(!EnableSessionFilter) return true;

   int gmtHour = GetGMTHour();

   if(TradeAsianSession && IsHourInSession(gmtHour, AsianStartHour, AsianEndHour)) {
      return true;
   }

   if(TradeLondonSession && IsHourInSession(gmtHour, LondonStartHour, LondonEndHour)) {
      return true;
   }

   if(TradeNewYorkSession && IsHourInSession(gmtHour, NewYorkStartHour, NewYorkEndHour)) {
      return true;
   }

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

   // Apply min/max limits
   double minRisk = balance * MinRiskPercent / 100.0;
   double maxRisk = balance * MaxRiskPercent / 100.0;

   if(riskAmount < minRisk) riskAmount = minRisk;
   if(riskAmount > maxRisk) riskAmount = maxRisk;

   return riskAmount;
}

//+------------------------------------------------------------------+
//| Calculate Lot Size                                               |
//+------------------------------------------------------------------+
double CalculateLotSize(double slPips) {
   if(slPips <= 0) slPips = MinSLPips;

   double riskAmount = GetRiskAmount();
   double pipValuePerLot = g_calc.GetPipValueForLots(1.0);

   if(pipValuePerLot <= 0) pipValuePerLot = g_calc.GetFallbackPipValue(1.0);

   double rawLots = riskAmount / (slPips * pipValuePerLot);
   double lots = g_calc.NormalizeLots(rawLots);

   Log(g_symbol + " LOT: Risk=$" + DoubleToString(riskAmount, 2) +
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
bool IsNewBar(int tfIndex) {
   ENUM_TIMEFRAMES tf = (tfIndex == TF_H1) ? HTF_Timeframe : LTF_Timeframe;
   datetime currentBarTime = iTime(g_symbol, tf, 0);

   if(currentBarTime == 0) return false;

   if(currentBarTime != g_lastBarTime[tfIndex]) {
      g_lastBarTime[tfIndex] = currentBarTime;
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
bool CheckEngulfingAboveBelowEMA(ENGULF_TYPE engulfType, int barIndex = 1) {
   double emaFast[], emaSlow[];
   if(!GetEMAValues(g_emaFastHandle[TF_H1], emaFast, barIndex + 1)) return false;
   if(!GetEMAValues(g_emaSlowHandle[TF_H1], emaSlow, barIndex + 1)) return false;

   double close = iClose(g_symbol, HTF_Timeframe, barIndex);
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
//| Check if Price is in EMA Zone (Retest)                           |
//+------------------------------------------------------------------+
bool IsPriceInEMAZone(int tfIndex, int barIndex = 1) {
   ENUM_TIMEFRAMES tf = (tfIndex == TF_H1) ? HTF_Timeframe : LTF_Timeframe;
   int fastHandle = g_emaFastHandle[tfIndex];
   int slowHandle = g_emaSlowHandle[tfIndex];

   double emaFast[], emaSlow[];
   if(!GetEMAValues(fastHandle, emaFast, barIndex + 1)) return false;
   if(!GetEMAValues(slowHandle, emaSlow, barIndex + 1)) return false;

   double low = iLow(g_symbol, tf, barIndex);
   double high = iHigh(g_symbol, tf, barIndex);

   double emaUpper = MathMax(emaFast[barIndex], emaSlow[barIndex]);
   double emaLower = MathMin(emaFast[barIndex], emaSlow[barIndex]);

   bool touchesZone = (low <= emaUpper && high >= emaLower);

   return touchesZone;
}

//+------------------------------------------------------------------+
//| Add Visual EMA Indicators to Chart                               |
//+------------------------------------------------------------------+
int g_emaFastVisual = INVALID_HANDLE;
int g_emaSlowVisual = INVALID_HANDLE;

void AddVisualEMAs() {
   long chartId = ChartID();
   ENUM_TIMEFRAMES tf = (ENUM_TIMEFRAMES)Period();

   // Create EMA Fast indicator for current timeframe
   g_emaFastVisual = iMA(g_symbol, tf, EMA_Fast_Period, 0, MODE_EMA, EMA_Price);
   if(g_emaFastVisual != INVALID_HANDLE) {
      ChartIndicatorAdd(chartId, 0, g_emaFastVisual);
   }

   // Create EMA Slow indicator for current timeframe
   g_emaSlowVisual = iMA(g_symbol, tf, EMA_Slow_Period, 0, MODE_EMA, EMA_Price);
   if(g_emaSlowVisual != INVALID_HANDLE) {
      ChartIndicatorAdd(chartId, 0, g_emaSlowVisual);
   }

   Log("Visual EMAs added: EMA " + IntegerToString(EMA_Fast_Period) + " & EMA " + IntegerToString(EMA_Slow_Period), "INIT");
   Log("To change colors: Right-click on EMA line -> Properties -> Colors", "INIT");
}

//+------------------------------------------------------------------+
//| Remove Visual EMA Indicators from Chart                          |
//+------------------------------------------------------------------+
void RemoveVisualEMAs() {
   long chartId = ChartID();
   int total = ChartIndicatorsTotal(chartId, 0);

   for(int i = total - 1; i >= 0; i--) {
      string name = ChartIndicatorName(chartId, 0, i);
      if(StringFind(name, "MA(") >= 0) {
         ChartIndicatorDelete(chartId, 0, name);
      }
   }

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
//| Initialize Gold Symbol                                           |
//+------------------------------------------------------------------+
bool InitGoldSymbol() {
   string symbolName = "XAUUSD";
   string actualSymbol = symbolName;

   if(!SymbolSelect(symbolName, true)) {
      string suffixes[] = {"", ".pro", ".ecn", ".raw", "m", ".", "#", "-", "_"};
      string goldVariations[] = {"XAUUSD", "GOLD", "XAUUSDm", "GOLDm"};
      bool found = false;

      for(int g = 0; g < ArraySize(goldVariations) && !found; g++) {
         for(int i = 0; i < ArraySize(suffixes) && !found; i++) {
            string testSymbol = goldVariations[g] + suffixes[i];
            if(SymbolSelect(testSymbol, true)) {
               actualSymbol = testSymbol;
               found = true;
            }
         }
      }

      if(!found) {
         Log("Gold symbol not available", "ERROR");
         return false;
      }
   }

   if(!g_calc.Init(actualSymbol, MaxSpread_XAUUSD)) {
      Log("Failed to initialize calculator for " + actualSymbol, "ERROR");
      return false;
   }

   g_symbol = actualSymbol;
   g_symbolEnabled = true;

   // Create indicator handles for calculations
   g_emaFastHandle[TF_H1] = iMA(actualSymbol, HTF_Timeframe, EMA_Fast_Period, 0, MODE_EMA, EMA_Price);
   g_emaSlowHandle[TF_H1] = iMA(actualSymbol, HTF_Timeframe, EMA_Slow_Period, 0, MODE_EMA, EMA_Price);
   g_atrHandle[TF_H1] = iATR(actualSymbol, HTF_Timeframe, ATR_Period);

   g_emaFastHandle[TF_M5] = iMA(actualSymbol, LTF_Timeframe, EMA_Fast_Period, 0, MODE_EMA, EMA_Price);
   g_emaSlowHandle[TF_M5] = iMA(actualSymbol, LTF_Timeframe, EMA_Slow_Period, 0, MODE_EMA, EMA_Price);
   g_atrHandle[TF_M5] = iATR(actualSymbol, LTF_Timeframe, ATR_Period);

   if(g_emaFastHandle[TF_H1] == INVALID_HANDLE ||
      g_emaSlowHandle[TF_H1] == INVALID_HANDLE ||
      g_emaFastHandle[TF_M5] == INVALID_HANDLE ||
      g_emaSlowHandle[TF_M5] == INVALID_HANDLE ||
      g_atrHandle[TF_M5] == INVALID_HANDLE) {
      Log("Failed to create indicators for " + actualSymbol, "ERROR");
      g_symbolEnabled = false;
      return false;
   }

   // Add visual EMA indicators to chart
   AddVisualEMAs();

   // Initialize state
   ResetState();

   // Log pip value calculation for verification
   double testPipValue = g_calc.GetPipValueForLots(1.0);
   Log("Initialized " + actualSymbol +
       " | PipSize: " + DoubleToString(g_calc.GetPipSize(), 5) +
       " | PipValue: $" + DoubleToString(testPipValue, 2) + "/lot" +
       " | Digits: " + IntegerToString(g_calc.GetDigits()), "INIT");

   // Warn if pip value seems off (should be around $10 for Gold)
   if(testPipValue < 5.0 || testPipValue > 15.0) {
      Log("WARNING: Gold pip value ($" + DoubleToString(testPipValue, 2) +
          ") outside expected range ($5-$15). Using fallback $10/lot.", "WARN");
   }

   return true;
}

//+------------------------------------------------------------------+
//| Reset State                                                      |
//+------------------------------------------------------------------+
void ResetState() {
   SIGNAL_STATE oldState = g_signalState;

   LogVerbose(g_symbol + " ResetState called. Old state: " + GetStateName(oldState) +
              " BatchCount: " + IntegerToString(g_batchCount), "RESET");

   g_signalState = STATE_WAITING_H1_SIGNAL;
   g_h1Direction = TREND_NONE;
   g_h1SignalTime = 0;
   g_h1SignalPrice = 0;
   g_h1EngulfType = ENGULF_NONE;
   g_m5RetestDetected = false;
   g_m5RetestTime = 0;
   g_m5EngulfDetected = false;
   g_batchCount = 0;

   // Reset trade info
   ZeroMemory(g_trade1_1);
   ZeroMemory(g_trade1_2);
   ZeroMemory(g_trade2_1);
   ZeroMemory(g_trade2_2);

   Log(g_symbol + " State machine RESET -> WAITING_H1_SIGNAL", "STATE");
}

//+------------------------------------------------------------------+
//| Check H1 for Engulfing Signal                                    |
//+------------------------------------------------------------------+
void CheckH1Signal() {
   if(!IsNewBar(TF_H1)) return;

   // Track activity - NEW H1 BAR DETECTED
   g_lastH1BarCheck = TimeCurrent();
   g_h1BarsAnalyzed++;

   if(g_signalState != STATE_WAITING_H1_SIGNAL) {
      g_lastH1Result = "State: " + GetStateName(g_signalState);
      Log("[H1 BAR #" + IntegerToString(g_h1BarsAnalyzed) + "] Skipped - Already have signal, state: " + GetStateName(g_signalState), "H1_CHECK");
      return;
   }

   ENGULF_TYPE engulf = DetectEngulfing(g_symbol, HTF_Timeframe, 1);

   if(engulf == ENGULF_NONE) {
      g_lastH1Result = "No engulfing pattern";
      Log("[H1 BAR #" + IntegerToString(g_h1BarsAnalyzed) + "] Checked - No engulfing pattern detected", "H1_CHECK");
      return;
   }

   // Found engulfing, check EMA position
   if(!CheckEngulfingAboveBelowEMA(engulf, 1)) {
      if(!IsPriceInEMAZone(TF_H1, 1)) {
         g_lastH1Result = GetEngulfName(engulf) + " - Not at EMA";
         Log("[H1 BAR #" + IntegerToString(g_h1BarsAnalyzed) + "] Found " + GetEngulfName(engulf) + " but NOT at EMA zone - No signal", "H1_CHECK");
         return;
      }
   }

   // Valid H1 signal
   g_h1EngulfType = engulf;
   g_h1SignalTime = iTime(g_symbol, HTF_Timeframe, 1);
   g_h1SignalPrice = iClose(g_symbol, HTF_Timeframe, 1);

   if(engulf == ENGULF_SINGLE_BULLISH || engulf == ENGULF_DOUBLE_BULLISH) {
      g_h1Direction = TREND_BULLISH;
   } else {
      g_h1Direction = TREND_BEARISH;
   }

   g_signalState = STATE_WAITING_M5_RETEST;
   g_m5RetestDetected = false;
   g_m5EngulfDetected = false;

   // Update stats
   g_stats.h1SignalsDetected++;

   // Activity tracking - SIGNAL FOUND
   g_lastH1Result = ">>> " + (g_h1Direction == TREND_BULLISH ? "BUY" : "SELL") + " SIGNAL <<<";

   Log("========================================", "H1_SIGNAL");
   Log("[H1 BAR #" + IntegerToString(g_h1BarsAnalyzed) + "] >>> H1 SIGNAL DETECTED <<<", "H1_SIGNAL");
   Log("Type: " + GetEngulfName(engulf), "H1_SIGNAL");
   Log("Direction: " + (g_h1Direction == TREND_BULLISH ? "BULLISH" : "BEARISH"), "H1_SIGNAL");
   Log("Price: " + DoubleToString(g_h1SignalPrice, g_calc.GetDigits()), "H1_SIGNAL");
   Log("Now waiting for M5 retest...", "H1_SIGNAL");
   Log("========================================", "H1_SIGNAL");
}

//+------------------------------------------------------------------+
//| Check M5 for Retest                                              |
//+------------------------------------------------------------------+
void CheckM5Retest() {
   // Track M5 activity on every new M5 bar
   static datetime lastM5Bar = 0;
   datetime currentM5Bar = iTime(g_symbol, LTF_Timeframe, 0);

   if(currentM5Bar != lastM5Bar) {
      lastM5Bar = currentM5Bar;
      g_lastM5BarCheck = TimeCurrent();
      g_m5BarsAnalyzed++;

      // Log M5 check
      g_lastM5Result = "Waiting for EMA retest...";
      Log("[M5 BAR #" + IntegerToString(g_m5BarsAnalyzed) + "] Checking for EMA zone retest", "M5_CHECK");
   }

   if(IsPriceInEMAZone(TF_M5, 0)) {
      if(!g_m5RetestDetected) {
         g_m5RetestDetected = true;
         g_m5RetestTime = TimeCurrent();
         g_signalState = STATE_WAITING_M5_ENGULFING;

         // Activity tracking - RETEST FOUND
         g_lastM5Result = ">>> RETEST DETECTED <<<";

         Log("[M5 BAR #" + IntegerToString(g_m5BarsAnalyzed) + "] >>> M5 RETEST DETECTED <<<", "M5_RETEST");
         Log("Now waiting for M5 engulfing confirmation...", "M5_RETEST");
      }
   }
}

//+------------------------------------------------------------------+
//| Check M5 for Engulfing Entry                                     |
//+------------------------------------------------------------------+
void CheckM5Engulfing() {
   if(!IsNewBar(TF_M5)) return;

   // Track M5 activity
   g_lastM5BarCheck = TimeCurrent();
   g_m5BarsAnalyzed++;

   ENGULF_TYPE engulf = DetectEngulfing(g_symbol, LTF_Timeframe, 1);

   if(engulf == ENGULF_NONE) {
      g_lastM5Result = "No engulfing pattern";
      Log("[M5 BAR #" + IntegerToString(g_m5BarsAnalyzed) + "] Checked - No engulfing pattern", "M5_CHECK");
      return;
   }

   bool validEngulf = false;
   if(g_h1Direction == TREND_BULLISH) {
      validEngulf = (engulf == ENGULF_SINGLE_BULLISH || engulf == ENGULF_DOUBLE_BULLISH);
   } else if(g_h1Direction == TREND_BEARISH) {
      validEngulf = (engulf == ENGULF_SINGLE_BEARISH || engulf == ENGULF_DOUBLE_BEARISH);
   }

   if(!validEngulf) {
      g_lastM5Result = GetEngulfName(engulf) + " - Wrong direction";
      Log("[M5 BAR #" + IntegerToString(g_m5BarsAnalyzed) + "] Found " + GetEngulfName(engulf) + " but wrong direction - Skipping", "M5_CHECK");
      return;
   }

   // Activity tracking - VALID M5 ENGULFING
   g_lastM5Result = ">>> " + GetEngulfName(engulf) + " - ENTRY <<<";

   Log("[M5 BAR #" + IntegerToString(g_m5BarsAnalyzed) + "] >>> M5 ENGULFING DETECTED <<<", "M5_ENTRY");
   Log("Type: " + GetEngulfName(engulf), "M5_ENTRY");

   ExecuteTradeBatch();
}

//+------------------------------------------------------------------+
//| Execute Trade Batch (2 trades: 1:1 RR and 1:2 RR)                |
//+------------------------------------------------------------------+
void ExecuteTradeBatch() {
   int digits = g_calc.GetDigits();
   bool isBuy = (g_h1Direction == TREND_BULLISH);

   Log("==========================================", "TRADE");
   Log(">>> " + g_symbol + " EXECUTING TRADE BATCH " + IntegerToString(g_batchCount + 1) + " <<<", "TRADE");

   // Check spread
   if(!g_calc.IsSpreadOK()) {
      Log("Spread too high: " + DoubleToString(g_calc.GetSpreadPips(), 1) + " pips - SKIPPING", "TRADE");
      return;
   }

   // Get entry price
   double entry = isBuy ? SymbolInfoDouble(g_symbol, SYMBOL_ASK) : SymbolInfoDouble(g_symbol, SYMBOL_BID);

   // Calculate SL using M5 ATR
   double atr = GetATR(g_atrHandle[TF_M5], 1);
   double slDistance = atr * ATR_Multiplier;

   double slPips = g_calc.ToPips(slDistance) + SpreadBufferPips;

   // Apply min/max SL limits
   if(slPips < MinSLPips) slPips = MinSLPips;
   if(slPips > MaxSLPips) slPips = MaxSLPips;

   slDistance = g_calc.ToPrice(slPips);

   double sl;
   if(isBuy) {
      sl = entry - slDistance;
   } else {
      sl = entry + slDistance;
   }

   // Calculate TP for both trades
   double tp1Distance = slDistance * RR_Trade1;
   double tp2Distance = slDistance * RR_Trade2;

   double tp1, tp2;
   if(isBuy) {
      tp1 = entry + tp1Distance;
      tp2 = entry + tp2Distance;
   } else {
      tp1 = entry - tp1Distance;
      tp2 = entry - tp2Distance;
   }

   // Calculate lot size
   double lots = CalculateLotSize(slPips);

   if(lots < g_calc.GetMinLot()) {
      Log("Lot size too small - SKIPPING", "TRADE");
      return;
   }

   Log("Entry: " + DoubleToString(entry, digits), "TRADE");
   Log("SL: " + DoubleToString(sl, digits) + " (" + DoubleToString(slPips, 1) + " pips | ATR: " + DoubleToString(atr, digits) + ")", "TRADE");
   Log("TP1 (1:" + DoubleToString(RR_Trade1, 1) + "): " + DoubleToString(tp1, digits), "TRADE");
   Log("TP2 (1:" + DoubleToString(RR_Trade2, 1) + "): " + DoubleToString(tp2, digits), "TRADE");
   Log("Lots: " + DoubleToString(lots, 2) + " per trade", "TRADE");

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(30);

   // Track successful trades
   bool success1 = false;
   bool success2 = false;

   // Execute Trade 1 (1:1 RR)
   string comment1 = "GOLD_B" + IntegerToString(g_batchCount + 1) + "_T1_" +
                     (isBuy ? "BUY" : "SELL") + "_1:" + DoubleToString(RR_Trade1, 0);

   if(isBuy) {
      success1 = trade.Buy(lots, g_symbol, 0, sl, tp1, comment1);
   } else {
      success1 = trade.Sell(lots, g_symbol, 0, sl, tp1, comment1);
   }

   if(success1) {
      Log("Trade 1 (1:" + DoubleToString(RR_Trade1, 0) + " RR) OPENED - Ticket: " + IntegerToString(trade.ResultOrder()), "SUCCESS");

      if(g_batchCount == 0) {
         g_trade1_1.ticket = trade.ResultOrder();
         g_trade1_1.entryPrice = trade.ResultPrice();
         g_trade1_1.sl = sl;
         g_trade1_1.tp = tp1;
         g_trade1_1.lots = lots;
         g_trade1_1.rrRatio = RR_Trade1;
         g_trade1_1.isOpen = true;
         g_trade1_1.hitTP = false;
         g_trade1_1.openTime = TimeCurrent();
      } else {
         g_trade2_1.ticket = trade.ResultOrder();
         g_trade2_1.entryPrice = trade.ResultPrice();
         g_trade2_1.sl = sl;
         g_trade2_1.tp = tp1;
         g_trade2_1.lots = lots;
         g_trade2_1.rrRatio = RR_Trade1;
         g_trade2_1.isOpen = true;
         g_trade2_1.hitTP = false;
         g_trade2_1.openTime = TimeCurrent();
      }

      g_dailyTrades++;
   } else {
      Log("Trade 1 FAILED: " + trade.ResultRetcodeDescription(), "ERROR");
   }

   // Execute Trade 2 (1:2 RR)
   string comment2 = "GOLD_B" + IntegerToString(g_batchCount + 1) + "_T2_" +
                     (isBuy ? "BUY" : "SELL") + "_1:" + DoubleToString(RR_Trade2, 0);

   if(isBuy) {
      success2 = trade.Buy(lots, g_symbol, 0, sl, tp2, comment2);
   } else {
      success2 = trade.Sell(lots, g_symbol, 0, sl, tp2, comment2);
   }

   if(success2) {
      Log("Trade 2 (1:" + DoubleToString(RR_Trade2, 0) + " RR) OPENED - Ticket: " + IntegerToString(trade.ResultOrder()), "SUCCESS");

      if(g_batchCount == 0) {
         g_trade1_2.ticket = trade.ResultOrder();
         g_trade1_2.entryPrice = trade.ResultPrice();
         g_trade1_2.sl = sl;
         g_trade1_2.tp = tp2;
         g_trade1_2.lots = lots;
         g_trade1_2.rrRatio = RR_Trade2;
         g_trade1_2.isOpen = true;
         g_trade1_2.hitTP = false;
         g_trade1_2.openTime = TimeCurrent();
      } else {
         g_trade2_2.ticket = trade.ResultOrder();
         g_trade2_2.entryPrice = trade.ResultPrice();
         g_trade2_2.sl = sl;
         g_trade2_2.tp = tp2;
         g_trade2_2.lots = lots;
         g_trade2_2.rrRatio = RR_Trade2;
         g_trade2_2.isOpen = true;
         g_trade2_2.hitTP = false;
         g_trade2_2.openTime = TimeCurrent();
      }

      g_dailyTrades++;
   } else {
      Log("Trade 2 FAILED: " + trade.ResultRetcodeDescription(), "ERROR");
   }

   // Only increment batch count if at least one trade succeeded
   if(success1 || success2) {
      g_batchCount++;
      g_stats.h1SignalsTraded++;

      // Update batch stats
      if(g_batchCount == 1) {
         g_stats.batch1Trades += (success1 ? 1 : 0) + (success2 ? 1 : 0);
      } else {
         g_stats.batch2Trades += (success1 ? 1 : 0) + (success2 ? 1 : 0);
      }

      if(g_batchCount >= MaxBatchesPerH1Signal) {
         g_signalState = STATE_SIGNAL_COMPLETE;
         Log("Max batches reached - Waiting for new H1 signal", "TRADE");
      } else {
         if(g_batchCount == 1) {
            g_signalState = STATE_BATCH1_ACTIVE;
         } else {
            g_signalState = STATE_BATCH2_ACTIVE;
         }
      }
   } else {
      Log("Both trades failed - Not incrementing batch count", "ERROR");
   }

   // Reset M5 tracking for next potential batch
   g_m5RetestDetected = false;
   g_m5EngulfDetected = false;

   Log("==========================================", "TRADE");
}

//+------------------------------------------------------------------+
//| Monitor Active Trades                                            |
//+------------------------------------------------------------------+
void MonitorTrades() {
   // Check batch 1 trades
   if(g_signalState == STATE_BATCH1_ACTIVE) {
      // Check trade 1_1 (1:1 RR)
      if(g_trade1_1.isOpen && g_trade1_1.ticket > 0) {
         if(!PositionSelectByTicket(g_trade1_1.ticket)) {
            g_trade1_1.isOpen = false;
            UpdateTradeStats(g_trade1_1.ticket, true);

            if(CheckIfTPHit(g_trade1_1.ticket)) {
               g_trade1_1.hitTP = true;
               g_stats.trade1_1_TPHits++;
               Log(g_symbol + " Trade 1 (1:1 RR) HIT TP", "TP_HIT");
            } else {
               Log(g_symbol + " Trade 1 (1:1 RR) closed (SL or manual)", "TRADE");
            }
         }
      }

      // Check trade 1_2 (1:2 RR)
      if(g_trade1_2.isOpen && g_trade1_2.ticket > 0) {
         if(!PositionSelectByTicket(g_trade1_2.ticket)) {
            g_trade1_2.isOpen = false;
            UpdateTradeStats(g_trade1_2.ticket, false);

            if(CheckIfTPHit(g_trade1_2.ticket)) {
               g_trade1_2.hitTP = true;
               g_stats.trade1_2_TPHits++;
               Log(g_symbol + " Trade 2 (1:2 RR) HIT TP", "TP_HIT");
            } else {
               Log(g_symbol + " Trade 2 (1:2 RR) closed (SL or manual)", "TRADE");
            }
         }
      }

      // Check if both batch 1 trades are closed
      bool bothClosed = !g_trade1_1.isOpen && !g_trade1_2.isOpen;

      if(bothClosed) {
         if(g_trade1_1.hitTP && g_batchCount < MaxBatchesPerH1Signal) {
            g_signalState = STATE_WAITING_M5_RETEST2;
            g_m5RetestDetected = false;
            Log(g_symbol + " Batch 1 complete with TP - Waiting for second M5 retest...", "STATE");
         } else {
            g_signalState = STATE_SIGNAL_COMPLETE;
            Log(g_symbol + " Batch 1 complete - Signal finished", "STATE");
         }
      }
   }

   // Check batch 2 trades
   if(g_signalState == STATE_BATCH2_ACTIVE) {
      if(g_trade2_1.isOpen && g_trade2_1.ticket > 0) {
         if(!PositionSelectByTicket(g_trade2_1.ticket)) {
            g_trade2_1.isOpen = false;
            UpdateTradeStats(g_trade2_1.ticket, true);
            Log(g_symbol + " Batch 2 Trade 1 closed", "TRADE");
         }
      }

      if(g_trade2_2.isOpen && g_trade2_2.ticket > 0) {
         if(!PositionSelectByTicket(g_trade2_2.ticket)) {
            g_trade2_2.isOpen = false;
            UpdateTradeStats(g_trade2_2.ticket, false);
            Log(g_symbol + " Batch 2 Trade 2 closed", "TRADE");
         }
      }

      if(!g_trade2_1.isOpen && !g_trade2_2.isOpen) {
         g_signalState = STATE_SIGNAL_COMPLETE;
         Log(g_symbol + " Batch 2 complete - Signal finished", "STATE");
      }
   }

   // STATE_SIGNAL_COMPLETE: Reset for new signals
   if(g_signalState == STATE_SIGNAL_COMPLETE) {
      Log(g_symbol + " Resetting for new H1 signal", "RESET");
      ResetState();
   }
}

//+------------------------------------------------------------------+
//| Update Trade Stats from Closed Trade                             |
//+------------------------------------------------------------------+
void UpdateTradeStats(ulong ticket, bool isTrade1) {
   if(ticket == 0) return;

   if(!HistorySelectByPosition(ticket)) {
      HistorySelect(TimeCurrent() - 86400 * 7, TimeCurrent());
   }

   double profit = 0;
   int deals = HistoryDealsTotal();

   for(int i = deals - 1; i >= 0; i--) {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0) continue;

      ulong posId = HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
      if(posId == ticket) {
         ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
         if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY) {
            profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
            profit += HistoryDealGetDouble(dealTicket, DEAL_SWAP);
            profit += HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
            break;
         }
      }
   }

   // Update stats
   g_stats.totalTrades++;
   g_stats.netProfit += profit;

   // Track drawdown
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(currentBalance > g_stats.peakBalance) {
      g_stats.peakBalance = currentBalance;
   }
   double drawdown = g_stats.peakBalance - currentBalance;
   if(drawdown > g_stats.maxDrawdown) {
      g_stats.maxDrawdown = drawdown;
   }

   if(profit > 0) {
      g_stats.wins++;
      g_stats.grossProfit += profit;
      if(profit > g_stats.largestWin) {
         g_stats.largestWin = profit;
      }

      // Consecutive tracking
      g_stats.consecutiveWins++;
      g_stats.consecutiveLosses = 0;
      if(g_stats.consecutiveWins > g_stats.maxConsecutiveWins) {
         g_stats.maxConsecutiveWins = g_stats.consecutiveWins;
      }

      Log(g_symbol + " WIN: $" + DoubleToString(profit, 2) +
          " | Total P/L: $" + DoubleToString(g_stats.netProfit, 2), "STATS");
   } else if(profit < 0) {
      g_stats.losses++;
      g_stats.grossLoss += profit; // Will be negative
      if(profit < g_stats.largestLoss) {
         g_stats.largestLoss = profit;
      }

      // Consecutive tracking
      g_stats.consecutiveLosses++;
      g_stats.consecutiveWins = 0;
      if(g_stats.consecutiveLosses > g_stats.maxConsecutiveLosses) {
         g_stats.maxConsecutiveLosses = g_stats.consecutiveLosses;
      }

      Log(g_symbol + " LOSS: $" + DoubleToString(profit, 2) +
          " | Total P/L: $" + DoubleToString(g_stats.netProfit, 2), "STATS");
   }
}

//+------------------------------------------------------------------+
//| Check if Trade Hit TP                                            |
//+------------------------------------------------------------------+
bool CheckIfTPHit(ulong ticket) {
   if(!HistorySelectByPosition(ticket)) {
      HistorySelect(TimeCurrent() - 86400, TimeCurrent());
   }

   int deals = HistoryDealsTotal();
   for(int i = deals - 1; i >= 0; i--) {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0) continue;

      ulong posId = HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
      if(posId == ticket) {
         ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
         if(entry == DEAL_ENTRY_OUT) {
            double profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
            return (profit > 0);
         }
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Process Symbol                                                   |
//+------------------------------------------------------------------+
void ProcessSymbol() {
   if(!g_symbolEnabled) return;

   SIGNAL_STATE state = g_signalState;

   // Log current state periodically
   static datetime lastStateLog = 0;
   if(TimeCurrent() - lastStateLog > 300) {
      lastStateLog = TimeCurrent();
      if(state != STATE_WAITING_H1_SIGNAL) {
         Log(g_symbol + " Current state: " + GetStateName(state) +
             " | Batch: " + IntegerToString(g_batchCount) +
             " | H1 Signal Age: " + IntegerToString((int)((TimeCurrent() - g_h1SignalTime) / 60)) + " min", "STATUS");
      }
   }

   // Monitor active trades first
   MonitorTrades();

   // Re-check state after MonitorTrades
   state = g_signalState;

   // Check signal timeout and validity
   if(state != STATE_WAITING_H1_SIGNAL && state != STATE_SIGNAL_COMPLETE) {
      if(ShouldResetSignal()) {
         Log(g_symbol + " Signal RESET - Timeout or invalidated", "RESET");
         ResetState();
         return;
      }
   }

   state = g_signalState;

   switch(state) {
      case STATE_WAITING_H1_SIGNAL:
         CheckH1Signal();
         break;

      case STATE_WAITING_M5_RETEST:
      case STATE_WAITING_M5_RETEST2:
         CheckM5Retest();
         break;

      case STATE_WAITING_M5_ENGULFING:
         CheckM5Engulfing();
         break;

      case STATE_BATCH1_ACTIVE:
      case STATE_BATCH2_ACTIVE:
         // Trades being monitored by MonitorTrades()
         break;

      case STATE_SIGNAL_COMPLETE:
         // Already handled in MonitorTrades
         break;
   }
}

//+------------------------------------------------------------------+
//| Check if Signal Should Be Reset                                  |
//+------------------------------------------------------------------+
bool ShouldResetSignal() {
   SIGNAL_STATE state = g_signalState;

   // FAILSAFE: Active batch with no open trades
   if(state == STATE_BATCH1_ACTIVE || state == STATE_BATCH2_ACTIVE) {
      bool hasOpenTrades = g_trade1_1.isOpen || g_trade1_2.isOpen ||
                           g_trade2_1.isOpen || g_trade2_2.isOpen;

      if(!hasOpenTrades) {
         bool hasRealPositions = false;
         for(int p = PositionsTotal() - 1; p >= 0; p--) {
            if(PositionSelectByTicket(PositionGetTicket(p))) {
               if(PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
                  PositionGetString(POSITION_SYMBOL) == g_symbol) {
                  hasRealPositions = true;
                  break;
               }
            }
         }

         if(!hasRealPositions) {
            Log(g_symbol + " FAILSAFE: Batch state with no open trades - forcing reset", "FAILSAFE");
            return true;
         }
      }
   }

   // Only apply timeout for waiting states
   if(state != STATE_WAITING_M5_RETEST &&
      state != STATE_WAITING_M5_ENGULFING &&
      state != STATE_WAITING_M5_RETEST2) {
      return false;
   }

   // Check signal timeout
   if(SignalTimeoutHours > 0 && g_h1SignalTime > 0) {
      datetime elapsed = TimeCurrent() - g_h1SignalTime;
      int hoursElapsed = (int)(elapsed / 3600);

      if(hoursElapsed >= SignalTimeoutHours) {
         Log(g_symbol + " Signal timeout: " + IntegerToString(hoursElapsed) + " hours elapsed", "TIMEOUT");
         return true;
      }
   }

   // Check for stale signals
   if(ResetOnNewH1Bar && g_h1SignalTime > 0) {
      int barsSinceSignal = iBarShift(g_symbol, HTF_Timeframe, g_h1SignalTime);

      if(barsSinceSignal >= 2) {
         Log(g_symbol + " Signal stale: " + IntegerToString(barsSinceSignal) + " H1 bars since signal", "STALE");
         return true;
      }
   }

   // Check for opposite H1 engulfing
   if(ResetOnOppositeSignal && g_batchCount == 0) {
      static datetime lastCheckBar = 0;
      datetime currentH1Bar = iTime(g_symbol, HTF_Timeframe, 0);

      if(currentH1Bar != lastCheckBar) {
         lastCheckBar = currentH1Bar;

         ENGULF_TYPE currentEngulf = DetectEngulfing(g_symbol, HTF_Timeframe, 1);

         if(currentEngulf != ENGULF_NONE) {
            bool isBullish = (currentEngulf == ENGULF_SINGLE_BULLISH || currentEngulf == ENGULF_DOUBLE_BULLISH);
            bool isBearish = (currentEngulf == ENGULF_SINGLE_BEARISH || currentEngulf == ENGULF_DOUBLE_BEARISH);

            if((g_h1Direction == TREND_BULLISH && isBearish) ||
               (g_h1Direction == TREND_BEARISH && isBullish)) {
               Log(g_symbol + " Opposite H1 engulfing detected - invalidating signal", "INVALIDATE");
               return true;
            }
         }
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

      // Check for stuck states
      if(g_symbolEnabled) {
         SIGNAL_STATE state = g_signalState;

         bool hasOpenPositions = false;
         for(int p = PositionsTotal() - 1; p >= 0; p--) {
            if(PositionSelectByTicket(PositionGetTicket(p))) {
               if(PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
                  PositionGetString(POSITION_SYMBOL) == g_symbol) {
                  hasOpenPositions = true;
                  break;
               }
            }
         }

         if(!hasOpenPositions && state != STATE_WAITING_H1_SIGNAL) {
            Log(g_symbol + " Daily reset - State was: " + GetStateName(state) + " -> Resetting", "RESET");
            ResetState();
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

   if(DailyProfitTarget > 0 && g_dailyPnL >= DailyProfitTarget) {
      return false;
   }

   if(MaxTradesPerDay > 0 && g_dailyTrades >= MaxTradesPerDay) {
      return false;
   }

   return true;
}

//+------------------------------------------------------------------+
//| Expert Initialization                                            |
//+------------------------------------------------------------------+
int OnInit() {
   g_isTester = MQLInfoInteger(MQL_TESTER);
   g_isOptimization = MQLInfoInteger(MQL_OPTIMIZATION);

   Log("========================================", "INIT");
   Log("GOLD ENGULFING BOT v7.0 Starting", "INIT");
   Log("Strategy: H1 Engulfing -> M5 Retest + Engulfing -> Dual Trade", "INIT");
   Log("Trades: 1:" + DoubleToString(RR_Trade1, 0) + " RR + 1:" + DoubleToString(RR_Trade2, 0) + " RR", "INIT");
   Log("Max Batches per H1 Signal: " + IntegerToString(MaxBatchesPerH1Signal), "INIT");

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(30);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   // Initialize Gold symbol
   if(!InitGoldSymbol()) {
      Alert("Failed to initialize Gold symbol!");
      return INIT_FAILED;
   }

   // Initialize statistics
   ZeroMemory(g_stats);
   g_stats.testStartTime = TimeCurrent();
   g_stats.initialBalance = account.Balance();
   g_stats.peakBalance = g_stats.initialBalance;

   g_dailyResetTime = TimeCurrent();
   g_dailyStartBalance = account.Balance();

   EventSetMillisecondTimer(TimerIntervalMs);

   Log("Symbol: " + g_symbol, "INIT");
   Log("Risk: " + (UsePercentageRisk ? DoubleToString(RiskPercent, 1) + "%" : "$" + DoubleToString(RiskDollars, 2)) + " per trade", "INIT");
   Log("ATR SL: Period=" + IntegerToString(ATR_Period) + " x " + DoubleToString(ATR_Multiplier, 1) + " + " + IntegerToString(SpreadBufferPips) + "p buffer", "INIT");

   // Log session settings
   Log("--- SESSION SETTINGS ---", "INIT");
   if(EnableSessionFilter) {
      Log("Session Filter: ENABLED (Broker GMT Offset: " + IntegerToString(BrokerGMTOffset) + ")", "INIT");
      Log("Asian Session: " + (TradeAsianSession ? "ON" : "OFF") + " (" + IntegerToString(AsianStartHour) + ":00 - " + IntegerToString(AsianEndHour) + ":00 GMT)", "INIT");
      Log("London Session: " + (TradeLondonSession ? "ON" : "OFF") + " (" + IntegerToString(LondonStartHour) + ":00 - " + IntegerToString(LondonEndHour) + ":00 GMT)", "INIT");
      Log("New York Session: " + (TradeNewYorkSession ? "ON" : "OFF") + " (" + IntegerToString(NewYorkStartHour) + ":00 - " + IntegerToString(NewYorkEndHour) + ":00 GMT)", "INIT");
   } else {
      Log("Session Filter: DISABLED (Trading 24/7)", "INIT");
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

   // Periodic failsafe
   static datetime lastFailsafeCheck = 0;
   if(TimeCurrent() - lastFailsafeCheck > 60) {
      lastFailsafeCheck = TimeCurrent();
      CheckStuckStates();
   }

   if(!CheckDailyLimits()) {
      UpdateChartComment("DAILY LIMIT REACHED");
      return;
   }

   // Check trading session
   if(!IsTradingAllowedInSession()) {
      static datetime lastSessionLog = 0;
      if(TimeCurrent() - lastSessionLog > 3600) {
         string currentSession = GetCurrentSessionName();
         Log("Session Filter Active | Current: " + currentSession +
             " | GMT Hour: " + IntegerToString(GetGMTHour()), "SESSION");
         lastSessionLog = TimeCurrent();
      }
      UpdateChartComment("SESSION FILTER - OFF HOURS");
      return;
   }

   ProcessSymbol();
   UpdateChartComment("");
}

//+------------------------------------------------------------------+
//| Update Chart Comment (Visual Status Display)                     |
//+------------------------------------------------------------------+
void UpdateChartComment(string extraStatus = "") {
   string status = "";
   status += "=== GOLD ENGULFING BOT v7.0 ===\n";
   status += "Symbol: " + g_symbol + "\n";
   status += "State: " + GetStateName(g_signalState) + "\n";
   status += "Batch: " + IntegerToString(g_batchCount) + "/" + IntegerToString(MaxBatchesPerH1Signal) + "\n";
   status += "Direction: " + (g_h1Direction == TREND_BULLISH ? "BULLISH" : (g_h1Direction == TREND_BEARISH ? "BEARISH" : "NONE")) + "\n";

   if(g_h1SignalTime > 0) {
      int minsAgo = (int)((TimeCurrent() - g_h1SignalTime) / 60);
      status += "H1 Signal: " + IntegerToString(minsAgo) + " mins ago\n";
   }

   status += "Spread: " + DoubleToString(g_calc.GetSpreadPips(), 1) + "/" + DoubleToString(MaxSpread_XAUUSD, 1) + " pips\n";
   status += "Daily Trades: " + IntegerToString(g_dailyTrades) + "\n";
   status += "Daily P/L: $" + DoubleToString(g_dailyPnL, 2) + "\n";

   // Show open positions
   int openPos = 0;
   if(g_trade1_1.isOpen) openPos++;
   if(g_trade1_2.isOpen) openPos++;
   if(g_trade2_1.isOpen) openPos++;
   if(g_trade2_2.isOpen) openPos++;
   status += "Open Positions: " + IntegerToString(openPos) + "\n";

   // === ACTIVITY MONITORING ===
   status += "\n--- ACTIVITY MONITOR ---\n";
   status += "H1 Bars Analyzed: " + IntegerToString(g_h1BarsAnalyzed) + "\n";
   status += "M5 Bars Analyzed: " + IntegerToString(g_m5BarsAnalyzed) + "\n";

   // Last H1 check info
   if(g_lastH1BarCheck > 0) {
      int secsAgoH1 = (int)(TimeCurrent() - g_lastH1BarCheck);
      int minsAgoH1 = secsAgoH1 / 60;
      status += "Last H1 Check: " + (minsAgoH1 > 0 ? IntegerToString(minsAgoH1) + "m " : "") +
                IntegerToString(secsAgoH1 % 60) + "s ago\n";
      status += "H1 Result: " + g_lastH1Result + "\n";
   } else {
      status += "Last H1 Check: Waiting for H1 bar...\n";
   }

   // Last M5 check info
   if(g_lastM5BarCheck > 0) {
      int secsAgoM5 = (int)(TimeCurrent() - g_lastM5BarCheck);
      int minsAgoM5 = secsAgoM5 / 60;
      status += "Last M5 Check: " + (minsAgoM5 > 0 ? IntegerToString(minsAgoM5) + "m " : "") +
                IntegerToString(secsAgoM5 % 60) + "s ago\n";
      status += "M5 Result: " + g_lastM5Result + "\n";
   } else if(g_signalState != STATE_WAITING_H1_SIGNAL) {
      status += "Last M5 Check: Waiting for M5 bar...\n";
   }

   if(extraStatus != "") {
      status += "\n>>> " + extraStatus + " <<<\n";
   }

   status += "\nLast Update: " + TimeToString(TimeCurrent(), TIME_SECONDS);

   Comment(status);
}

//+------------------------------------------------------------------+
//| Check for Stuck States (Failsafe)                                |
//+------------------------------------------------------------------+
void CheckStuckStates() {
   if(!g_symbolEnabled) return;

   SIGNAL_STATE state = g_signalState;

   if(state == STATE_WAITING_H1_SIGNAL) return;

   bool hasRealPositions = false;
   for(int p = PositionsTotal() - 1; p >= 0; p--) {
      ulong ticket = PositionGetTicket(p);
      if(ticket > 0 && PositionSelectByTicket(ticket)) {
         if(PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
            PositionGetString(POSITION_SYMBOL) == g_symbol) {
            hasRealPositions = true;
            break;
         }
      }
   }

   if((state == STATE_BATCH1_ACTIVE || state == STATE_BATCH2_ACTIVE) && !hasRealPositions) {
      Log(g_symbol + " STUCK STATE DETECTED: " + GetStateName(state) + " with no positions - Resetting", "FAILSAFE");
      ResetState();
      return;
   }

   // Long-stuck waiting states
   if(state == STATE_WAITING_M5_RETEST ||
      state == STATE_WAITING_M5_ENGULFING ||
      state == STATE_WAITING_M5_RETEST2 ||
      state == STATE_SIGNAL_COMPLETE) {

      if(g_h1SignalTime > 0) {
         int hoursStuck = (int)((TimeCurrent() - g_h1SignalTime) / 3600);
         if(hoursStuck >= 12) {
            Log(g_symbol + " STUCK STATE DETECTED: " + GetStateName(state) +
                " for " + IntegerToString(hoursStuck) + " hours - Resetting", "FAILSAFE");
            ResetState();
         }
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

   // Set end time for statistics
   g_stats.testEndTime = TimeCurrent();

   // Print comprehensive statistics
   PrintTradeStatistics();

   // Release indicator handles
   if(g_symbolEnabled) {
      if(g_emaFastHandle[TF_H1] != INVALID_HANDLE)
         IndicatorRelease(g_emaFastHandle[TF_H1]);
      if(g_emaSlowHandle[TF_H1] != INVALID_HANDLE)
         IndicatorRelease(g_emaSlowHandle[TF_H1]);
      if(g_emaFastHandle[TF_M5] != INVALID_HANDLE)
         IndicatorRelease(g_emaFastHandle[TF_M5]);
      if(g_emaSlowHandle[TF_M5] != INVALID_HANDLE)
         IndicatorRelease(g_emaSlowHandle[TF_M5]);
      if(g_atrHandle[TF_H1] != INVALID_HANDLE)
         IndicatorRelease(g_atrHandle[TF_H1]);
      if(g_atrHandle[TF_M5] != INVALID_HANDLE)
         IndicatorRelease(g_atrHandle[TF_M5]);
   }

   Comment("");  // Clear chart comment
   RemoveVisualEMAs();  // Remove EMA indicators from chart
   Log("Bot stopped. Daily trades: " + IntegerToString(g_dailyTrades), "DEINIT");
}

//+------------------------------------------------------------------+
//| Print Trade Statistics                                           |
//+------------------------------------------------------------------+
void PrintTradeStatistics() {
   double finalBalance = AccountInfoDouble(ACCOUNT_BALANCE);

   Print("");
   Print("================================================================================");
   Print("                    GOLD ENGULFING BOT v7.0 - TRADE REPORT                      ");
   Print("================================================================================");
   Print("");

   // Test Period Info
   Print("TEST PERIOD");
   Print("  Start:           ", TimeToString(g_stats.testStartTime, TIME_DATE|TIME_MINUTES));
   Print("  End:             ", TimeToString(g_stats.testEndTime, TIME_DATE|TIME_MINUTES));
   Print("  Duration:        ", GetDurationString(g_stats.testEndTime - g_stats.testStartTime));
   Print("");

   // Account Summary
   Print("ACCOUNT SUMMARY");
   Print("  Initial Balance: $", DoubleToString(g_stats.initialBalance, 2));
   Print("  Final Balance:   $", DoubleToString(finalBalance, 2));
   Print("  Net Change:      $", DoubleToString(g_stats.netProfit, 2), " (", DoubleToString(g_stats.ReturnPercent(), 2), "%)");
   Print("");

   // Performance Summary
   Print("--------------------------------------------------------------------------------");
   Print("                           PERFORMANCE SUMMARY                                  ");
   Print("--------------------------------------------------------------------------------");
   Print("  Total Net Profit:    $", DoubleToString(g_stats.netProfit, 2), " (", DoubleToString(g_stats.ReturnPercent(), 2), "%)");
   Print("  Gross Profit:        $", DoubleToString(g_stats.grossProfit, 2));
   Print("  Gross Loss:          $", DoubleToString(MathAbs(g_stats.grossLoss), 2));
   Print("  Profit Factor:       ", DoubleToString(g_stats.ProfitFactor(), 2));
   Print("  Max Drawdown:        $", DoubleToString(g_stats.maxDrawdown, 2), " (", DoubleToString(g_stats.DrawdownPercent(), 2), "%)");
   Print("");

   // Trade Statistics
   Print("--------------------------------------------------------------------------------");
   Print("                           TRADE STATISTICS                                     ");
   Print("--------------------------------------------------------------------------------");
   Print("  Total Trades:        ", IntegerToString(g_stats.totalTrades));
   Print("  Winning Trades:      ", IntegerToString(g_stats.wins), " (", DoubleToString(g_stats.WinRate(), 2), "%)");
   Print("  Losing Trades:       ", IntegerToString(g_stats.losses), " (", DoubleToString(100.0 - g_stats.WinRate(), 2), "%)");
   Print("  Average Win:         $", DoubleToString(g_stats.AvgWin(), 2));
   Print("  Average Loss:        $", DoubleToString(g_stats.AvgLoss(), 2));
   Print("  Largest Win:         $", DoubleToString(g_stats.largestWin, 2));
   Print("  Largest Loss:        $", DoubleToString(MathAbs(g_stats.largestLoss), 2));
   Print("  Expectancy:          $", DoubleToString(g_stats.Expectancy(), 2), " per trade");
   Print("");

   // Consecutive Stats
   Print("  Max Consecutive Wins:   ", IntegerToString(g_stats.maxConsecutiveWins));
   Print("  Max Consecutive Losses: ", IntegerToString(g_stats.maxConsecutiveLosses));
   Print("");

   // Signal Analysis
   Print("--------------------------------------------------------------------------------");
   Print("                           SIGNAL ANALYSIS                                      ");
   Print("--------------------------------------------------------------------------------");
   Print("  H1 Signals Detected: ", IntegerToString(g_stats.h1SignalsDetected));
   Print("  Signals Traded:      ", IntegerToString(g_stats.h1SignalsTraded), " (", DoubleToString(g_stats.SignalConversionRate(), 2), "% conversion)");
   Print("  Batch 1 Entries:     ", IntegerToString(g_stats.batch1Trades));
   Print("  Batch 2 Entries:     ", IntegerToString(g_stats.batch2Trades));
   Print("  1:1 RR Hit Rate:     ", DoubleToString(g_stats.Trade1_1_HitRate(), 2), "%");
   Print("  1:2 RR Hit Rate:     ", DoubleToString(g_stats.Trade1_2_HitRate(), 2), "%");
   Print("");

   // Settings Summary
   Print("--------------------------------------------------------------------------------");
   Print("                           SETTINGS USED                                        ");
   Print("--------------------------------------------------------------------------------");
   Print("  Symbol:              ", g_symbol);
   Print("  Risk per Trade:      ", UsePercentageRisk ? DoubleToString(RiskPercent, 1) + "%" : "$" + DoubleToString(RiskDollars, 2));
   Print("  RR Targets:          1:", DoubleToString(RR_Trade1, 0), " + 1:", DoubleToString(RR_Trade2, 0));
   Print("  ATR Period:          ", IntegerToString(ATR_Period), " x ", DoubleToString(ATR_Multiplier, 1));
   Print("  Max Batches:         ", IntegerToString(MaxBatchesPerH1Signal));
   Print("  Signal Timeout:      ", IntegerToString(SignalTimeoutHours), " hours");
   Print("");
   Print("================================================================================");
   Print("");
}

//+------------------------------------------------------------------+
//| Get Duration String                                              |
//+------------------------------------------------------------------+
string GetDurationString(datetime seconds) {
   int days = (int)(seconds / 86400);
   int hours = (int)((seconds % 86400) / 3600);
   int mins = (int)((seconds % 3600) / 60);

   string result = "";
   if(days > 0) result += IntegerToString(days) + " days ";
   if(hours > 0) result += IntegerToString(hours) + " hours ";
   result += IntegerToString(mins) + " mins";

   return result;
}
//+------------------------------------------------------------------+
