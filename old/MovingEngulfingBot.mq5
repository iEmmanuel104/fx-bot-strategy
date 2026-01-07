//+------------------------------------------------------------------+
//|                                         GoldEngulfingBot.mq5     |
//|                        EMA Crossover & Retest Multi-Symbol EA    |
//|                                                       Version 3.0|
//|                    SIGNAL BROADCAST MODE - For Multi-Account Use |
//|  Supports: XAUUSD, GBPUSD, GBPJPY                                |
//|  Strategy: H1 Engulfing + EMA -> M5 Retest + Engulfing -> Entry  |
//|  Features: Dual Trade (1:1 + 1:2 RR), ATR-based SL, 2 Batches    |
//+------------------------------------------------------------------+
#property copyright "FXBot Trading"
#property link      "https://fxbot.trading"
#property version   "3.00"
#property strict
#property description "EMA 10/23 Engulfing Strategy v3.0"
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
input int      MagicNumber = 247891;                      // Magic Number (different from v2)
input bool     EnableServerConnection = true;             // Connect to server
input int      HeartbeatIntervalSec = 30;                 // Heartbeat interval (seconds)

input group "=== Symbol Selection ==="
input bool     TradeXAUUSD = true;                        // Trade Gold (XAUUSD)
input bool     TradeGBPUSD = true;                        // Trade GBPUSD
input bool     TradeGBPJPY = true;                        // Trade GBPJPY

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

input group "=== Trade Batch Settings ==="
input int      MaxBatchesPerH1Signal = 2;                 // Max trade batches per H1 signal
input int      SignalTimeoutHours = 4;                    // Reset signal if no trade within X hours (0=disabled)
input bool     ResetOnNewH1Bar = true;                    // Reset if new H1 bar and no trades taken
input bool     ResetOnOppositeSignal = true;              // Reset if opposite H1 engulfing detected

input group "=== Position Limits ==="
input int      MaxPositionsPerSymbol = 10;                // Max positions per symbol
input int      MaxTotalPositions = 20;                    // Max total open positions
input double   MarginBufferPercent = 10.0;                // Margin safety buffer %

input group "=== Spread Limits (in Pips) ==="
input double   MaxSpread_XAUUSD = 15.0;                   // Max spread for Gold (pips)
input double   MaxSpread_GBPUSD = 4.0;                    // Max spread for GBPUSD (pips)
input double   MaxSpread_GBPJPY = 5.0;                    // Max spread for GBPJPY (pips)

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
#define MAX_SYMBOLS 3
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

enum SYMBOL_TYPE {
   SYMBOL_TYPE_GOLD = 0,
   SYMBOL_TYPE_MAJOR = 1,
   SYMBOL_TYPE_JPY = 2
};

//+------------------------------------------------------------------+
//| Symbol Calculator Class                                          |
//+------------------------------------------------------------------+
class CSymbolCalculator {
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
      
      if(StringFind(sym, "XAU") >= 0 || StringFind(sym, "GOLD") >= 0) {
         m_type = SYMBOL_TYPE_GOLD;
         m_pipSize = 0.1;
      }
      else if(StringFind(sym, "JPY") >= 0) {
         m_type = SYMBOL_TYPE_JPY;
         m_pipSize = 0.01;
      }
      else {
         m_type = SYMBOL_TYPE_MAJOR;
         m_pipSize = 0.0001;
      }
      
      m_pipValue = CalculatePipValueDynamic(1.0);
      if(m_pipValue <= 0) m_pipValue = GetFallbackPipValue(1.0);
      
      return (m_pipValue > 0);
   }
   
   double CalculatePipValueDynamic(double lots) {
      double bid = SymbolInfoDouble(m_symbol, SYMBOL_BID);
      if(bid <= 0) return GetFallbackPipValue(lots);
      
      double profit = 0;
      if(OrderCalcProfit(ORDER_TYPE_BUY, m_symbol, lots, bid, bid + m_pipSize, profit)) {
         if(profit > 0) return profit;
      }
      
      if(m_tickSize > 0 && m_tickValue > 0) {
         double tickBasedValue = (m_pipSize / m_tickSize) * m_tickValue * lots;
         if(tickBasedValue > 0) return tickBasedValue;
      }
      
      return GetFallbackPipValue(lots);
   }
   
   double GetFallbackPipValue(double lots) {
      switch(m_type) {
         case SYMBOL_TYPE_GOLD:  return 10.0 * lots;
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
         case SYMBOL_TYPE_GOLD:  return "GOLD";
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
//| Symbol Statistics Structure                                      |
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
   int      batch1Trades;
   int      batch2Trades;
   
   double WinRate() {
      if(totalTrades == 0) return 0;
      return (double)wins / totalTrades * 100.0;
   }
   
   double ProfitFactor() {
      if(grossLoss == 0) return grossProfit > 0 ? 999.99 : 0;
      return grossProfit / MathAbs(grossLoss);
   }
   
   double AvgWin() {
      if(wins == 0) return 0;
      return grossProfit / wins;
   }
   
   double AvgLoss() {
      if(losses == 0) return 0;
      return grossLoss / losses;
   }
   
   double Expectancy() {
      if(totalTrades == 0) return 0;
      return netProfit / totalTrades;
   }
};

//+------------------------------------------------------------------+
//| Symbol Configuration Structure                                   |
//+------------------------------------------------------------------+
struct SymbolConfig {
   string            name;
   bool              enabled;
   CSymbolCalculator calc;
   
   // Indicator handles [TF_H1, TF_M5]
   int               emaFastHandle[2];
   int               emaSlowHandle[2];
   int               atrHandle[2];
   
   // H1 Signal State
   SIGNAL_STATE      signalState;
   TREND_STATE       h1Direction;           // Direction from H1 engulfing
   datetime          h1SignalTime;          // When H1 signal was detected
   double            h1SignalPrice;         // Price at H1 signal
   ENGULF_TYPE       h1EngulfType;          // Type of H1 engulfing detected
   
   // M5 Tracking
   bool              m5RetestDetected;      // M5 touched EMA zone
   datetime          m5RetestTime;          // When M5 retest occurred
   bool              m5EngulfDetected;      // M5 engulfing after retest
   
   // Batch Tracking
   int               batchCount;            // 0, 1, or 2
   TradeInfo         trade1_1;              // Batch 1, Trade 1 (1:1 RR)
   TradeInfo         trade1_2;              // Batch 1, Trade 2 (1:2 RR)
   TradeInfo         trade2_1;              // Batch 2, Trade 1 (1:1 RR)
   TradeInfo         trade2_2;              // Batch 2, Trade 2 (1:2 RR)
   
   // Statistics
   SymbolStats       stats;
   
   // Bar tracking
   datetime          lastBarTime[2];
};

//+------------------------------------------------------------------+
//| Global Variables                                                 |
//+------------------------------------------------------------------+
CTrade trade;
CPositionInfo position;
CAccountInfo account;

SymbolConfig g_symbols[MAX_SYMBOLS];
int g_activeSymbols = 0;
string g_symbolNames[MAX_SYMBOLS] = {"XAUUSD", "GBPUSD", "GBPJPY"};
bool g_symbolEnabled[MAX_SYMBOLS];
double g_maxSpreads[MAX_SYMBOLS];

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
   // Handle sessions that don't cross midnight
   if(startHour < endHour) {
      return (gmtHour >= startHour && gmtHour < endHour);
   }
   // Handle sessions that cross midnight (e.g., 22:00 - 06:00)
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
   if(!EnableSessionFilter) return true;  // Session filter disabled, trade 24/7
   
   int gmtHour = GetGMTHour();
   
   // Check Asian Session
   if(TradeAsianSession && IsHourInSession(gmtHour, AsianStartHour, AsianEndHour)) {
      return true;
   }
   
   // Check London Session
   if(TradeLondonSession && IsHourInSession(gmtHour, LondonStartHour, LondonEndHour)) {
      return true;
   }
   
   // Check New York Session
   if(TradeNewYorkSession && IsHourInSession(gmtHour, NewYorkStartHour, NewYorkEndHour)) {
      return true;
   }
   
   return false;  // No enabled session is active
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
//| Check for New Bar                                                |
//+------------------------------------------------------------------+
bool IsNewBar(int symbolIndex, int tfIndex) {
   ENUM_TIMEFRAMES tf = (tfIndex == TF_H1) ? HTF_Timeframe : LTF_Timeframe;
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
   
   // Bullish Engulfing: prev bearish, curr bullish, curr body engulfs prev body
   bool prevBearish = (C2 < O2);
   bool currBullish = (C1 > O1);
   bool bullEngulfs = (C1 >= O2) && (O1 <= C2) && (body1 > body2);
   
   if(prevBearish && currBullish && bullEngulfs) {
      return ENGULF_SINGLE_BULLISH;
   }
   
   // Bearish Engulfing: prev bullish, curr bearish, curr body engulfs prev body
   bool prevBullish = (C2 > O2);
   bool currBearish = (C1 < O1);
   bool bearEngulfs = (O1 >= C2) && (C1 <= O2) && (body1 > body2);
   
   if(prevBullish && currBearish && bearEngulfs) {
      return ENGULF_SINGLE_BEARISH;
   }
   
   return ENGULF_NONE;
}

//+------------------------------------------------------------------+
//| Detect Double Candle Engulfing (2 candles together engulf prev)  |
//+------------------------------------------------------------------+
ENGULF_TYPE DetectDoubleEngulfing(string symbol, ENUM_TIMEFRAMES tf, int barIndex = 1) {
   // Current candle (bar 1) and previous candle (bar 2) together engulf bar 3
   double O1 = iOpen(symbol, tf, barIndex);
   double C1 = iClose(symbol, tf, barIndex);
   double O2 = iOpen(symbol, tf, barIndex + 1);
   double C2 = iClose(symbol, tf, barIndex + 1);
   double O3 = iOpen(symbol, tf, barIndex + 2);
   double C3 = iClose(symbol, tf, barIndex + 2);
   
   // Check if candles 1 and 2 are in same direction
   bool candle1Bullish = (C1 > O1);
   bool candle2Bullish = (C2 > O2);
   bool candle1Bearish = (C1 < O1);
   bool candle2Bearish = (C2 < O2);
   
   // Combined body of candles 1 and 2
   double combinedHigh = MathMax(MathMax(C1, O1), MathMax(C2, O2));
   double combinedLow = MathMin(MathMin(C1, O1), MathMin(C2, O2));
   
   // Previous candle (bar 3) body
   double prevBodyHigh = MathMax(C3, O3);
   double prevBodyLow = MathMin(C3, O3);
   
   // Bullish Double Engulfing
   bool prevBearish = (C3 < O3);
   bool bothBullish = candle1Bullish && candle2Bullish;
   bool bullEngulfs = (combinedHigh >= prevBodyHigh) && (combinedLow <= prevBodyLow);
   
   if(prevBearish && bothBullish && bullEngulfs) {
      return ENGULF_DOUBLE_BULLISH;
   }
   
   // Bearish Double Engulfing
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
   // Check single engulfing first
   ENGULF_TYPE single = DetectSingleEngulfing(symbol, tf, barIndex);
   if(single != ENGULF_NONE) return single;
   
   // Check double engulfing
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
   
   double close = iClose(symbol, HTF_Timeframe, barIndex);
   double emaUpper = MathMax(emaFast[barIndex], emaSlow[barIndex]);
   double emaLower = MathMin(emaFast[barIndex], emaSlow[barIndex]);
   
   // Bullish engulfing should close ABOVE the EMA lines
   if(engulfType == ENGULF_SINGLE_BULLISH || engulfType == ENGULF_DOUBLE_BULLISH) {
      return (close > emaUpper);
   }
   
   // Bearish engulfing should close BELOW the EMA lines
   if(engulfType == ENGULF_SINGLE_BEARISH || engulfType == ENGULF_DOUBLE_BEARISH) {
      return (close < emaLower);
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Check if Price is in EMA Zone (Retest)                           |
//+------------------------------------------------------------------+
bool IsPriceInEMAZone(int symbolIndex, int tfIndex, int barIndex = 1) {
   string symbol = g_symbols[symbolIndex].name;
   ENUM_TIMEFRAMES tf = (tfIndex == TF_H1) ? HTF_Timeframe : LTF_Timeframe;
   int fastHandle = g_symbols[symbolIndex].emaFastHandle[tfIndex];
   int slowHandle = g_symbols[symbolIndex].emaSlowHandle[tfIndex];
   
   double emaFast[], emaSlow[];
   if(!GetEMAValues(fastHandle, emaFast, barIndex + 1)) return false;
   if(!GetEMAValues(slowHandle, emaSlow, barIndex + 1)) return false;
   
   double low = iLow(symbol, tf, barIndex);
   double high = iHigh(symbol, tf, barIndex);
   
   double emaUpper = MathMax(emaFast[barIndex], emaSlow[barIndex]);
   double emaLower = MathMin(emaFast[barIndex], emaSlow[barIndex]);
   
   // Price touches zone if wick reaches into EMA zone
   bool touchesZone = (low <= emaUpper && high >= emaLower);
   
   return touchesZone;
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
      string suffixes[] = {"", ".pro", ".ecn", ".raw", "m", ".", "#", "-", "_"};
      string goldVariations[] = {"XAUUSD", "GOLD", "XAUUSDm", "GOLDm"};
      bool found = false;
      
      if(StringFind(symbolName, "XAU") >= 0 || StringFind(symbolName, "GOLD") >= 0) {
         for(int g = 0; g < ArraySize(goldVariations) && !found; g++) {
            for(int i = 0; i < ArraySize(suffixes) && !found; i++) {
               string testSymbol = goldVariations[g] + suffixes[i];
               if(SymbolSelect(testSymbol, true)) {
                  actualSymbol = testSymbol;
                  found = true;
               }
            }
         }
      }
      
      if(!found) {
         for(int i = 0; i < ArraySize(suffixes); i++) {
            string testSymbol = symbolName + suffixes[i];
            if(SymbolSelect(testSymbol, true)) {
               actualSymbol = testSymbol;
               found = true;
               break;
            }
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
   g_symbols[index].emaFastHandle[TF_H1] = iMA(actualSymbol, HTF_Timeframe, EMA_Fast_Period, 0, MODE_EMA, EMA_Price);
   g_symbols[index].emaSlowHandle[TF_H1] = iMA(actualSymbol, HTF_Timeframe, EMA_Slow_Period, 0, MODE_EMA, EMA_Price);
   g_symbols[index].atrHandle[TF_H1] = iATR(actualSymbol, HTF_Timeframe, ATR_Period);
   
   g_symbols[index].emaFastHandle[TF_M5] = iMA(actualSymbol, LTF_Timeframe, EMA_Fast_Period, 0, MODE_EMA, EMA_Price);
   g_symbols[index].emaSlowHandle[TF_M5] = iMA(actualSymbol, LTF_Timeframe, EMA_Slow_Period, 0, MODE_EMA, EMA_Price);
   g_symbols[index].atrHandle[TF_M5] = iATR(actualSymbol, LTF_Timeframe, ATR_Period);
   
   if(g_symbols[index].emaFastHandle[TF_H1] == INVALID_HANDLE ||
      g_symbols[index].emaSlowHandle[TF_H1] == INVALID_HANDLE ||
      g_symbols[index].emaFastHandle[TF_M5] == INVALID_HANDLE ||
      g_symbols[index].emaSlowHandle[TF_M5] == INVALID_HANDLE ||
      g_symbols[index].atrHandle[TF_M5] == INVALID_HANDLE) {
      Log("Failed to create indicators for " + actualSymbol, "ERROR");
      g_symbols[index].enabled = false;
      return false;
   }
   
   // Initialize state
   ResetSymbolState(index);
   
   g_activeSymbols++;
   
   Log("Initialized " + actualSymbol + 
       " | Type: " + g_symbols[index].calc.GetTypeName() +
       " | PipSize: " + DoubleToString(g_symbols[index].calc.GetPipSize(), 5) +
       " | PipValue: $" + DoubleToString(g_symbols[index].calc.GetPipValue(), 2), "INIT");
   
   return true;
}

//+------------------------------------------------------------------+
//| Reset Symbol State                                               |
//+------------------------------------------------------------------+
void ResetSymbolState(int symbolIndex) {
   string symbol = g_symbols[symbolIndex].name;
   SIGNAL_STATE oldState = g_symbols[symbolIndex].signalState;
   
   LogVerbose(symbol + " ResetSymbolState called. Old state: " + GetStateName(oldState) + 
              " BatchCount: " + IntegerToString(g_symbols[symbolIndex].batchCount), "RESET");
   
   g_symbols[symbolIndex].signalState = STATE_WAITING_H1_SIGNAL;
   g_symbols[symbolIndex].h1Direction = TREND_NONE;
   g_symbols[symbolIndex].h1SignalTime = 0;
   g_symbols[symbolIndex].h1SignalPrice = 0;
   g_symbols[symbolIndex].h1EngulfType = ENGULF_NONE;
   g_symbols[symbolIndex].m5RetestDetected = false;
   g_symbols[symbolIndex].m5RetestTime = 0;
   g_symbols[symbolIndex].m5EngulfDetected = false;
   g_symbols[symbolIndex].batchCount = 0;
   
   // Reset trade info
   ZeroMemory(g_symbols[symbolIndex].trade1_1);
   ZeroMemory(g_symbols[symbolIndex].trade1_2);
   ZeroMemory(g_symbols[symbolIndex].trade2_1);
   ZeroMemory(g_symbols[symbolIndex].trade2_2);
   
   // Don't reset lastBarTime - let it continue tracking naturally
   // g_symbols[symbolIndex].lastBarTime[TF_H1] = 0;
   // g_symbols[symbolIndex].lastBarTime[TF_M5] = 0;
   
   Log(symbol + " State machine RESET -> WAITING_H1_SIGNAL", "STATE");
}

//+------------------------------------------------------------------+
//| Check H1 for Engulfing Signal                                    |
//+------------------------------------------------------------------+
void CheckH1Signal(int symbolIndex) {
   string symbol = g_symbols[symbolIndex].name;
   
   // Only check on new H1 bar
   if(!IsNewBar(symbolIndex, TF_H1)) return;
   
   // Only check if we're waiting for H1 signal
   if(g_symbols[symbolIndex].signalState != STATE_WAITING_H1_SIGNAL) return;
   
   // Detect engulfing on completed bar (index 1)
   ENGULF_TYPE engulf = DetectEngulfing(symbol, HTF_Timeframe, 1);
   
   if(engulf == ENGULF_NONE) {
      LogVerbose(symbol + " H1 - No engulfing detected", "H1");
      return;
   }
   
   // Check if engulfing closed above/below EMA lines
   if(!CheckEngulfingAboveBelowEMA(symbolIndex, engulf, 1)) {
      // Also check if it's touching EMA zone (original condition)
      if(!IsPriceInEMAZone(symbolIndex, TF_H1, 1)) {
         LogVerbose(symbol + " H1 - Engulfing not at EMA zone", "H1");
         return;
      }
   }
   
   // We have a valid H1 signal!
   g_symbols[symbolIndex].h1EngulfType = engulf;
   g_symbols[symbolIndex].h1SignalTime = iTime(symbol, HTF_Timeframe, 1);
   g_symbols[symbolIndex].h1SignalPrice = iClose(symbol, HTF_Timeframe, 1);
   
   if(engulf == ENGULF_SINGLE_BULLISH || engulf == ENGULF_DOUBLE_BULLISH) {
      g_symbols[symbolIndex].h1Direction = TREND_BULLISH;
   } else {
      g_symbols[symbolIndex].h1Direction = TREND_BEARISH;
   }
   
   // Move to next state
   g_symbols[symbolIndex].signalState = STATE_WAITING_M5_RETEST;
   g_symbols[symbolIndex].m5RetestDetected = false;
   g_symbols[symbolIndex].m5EngulfDetected = false;
   
   // Update stats
   g_symbols[symbolIndex].stats.h1SignalsDetected++;
   
   Log("========================================", "H1_SIGNAL");
   Log(symbol + " >>> H1 SIGNAL DETECTED <<<", "H1_SIGNAL");
   Log("Type: " + GetEngulfName(engulf), "H1_SIGNAL");
   Log("Direction: " + (g_symbols[symbolIndex].h1Direction == TREND_BULLISH ? "BULLISH" : "BEARISH"), "H1_SIGNAL");
   Log("Price: " + DoubleToString(g_symbols[symbolIndex].h1SignalPrice, g_symbols[symbolIndex].calc.GetDigits()), "H1_SIGNAL");
   Log("Now waiting for M5 retest...", "H1_SIGNAL");
   Log("========================================", "H1_SIGNAL");
}

//+------------------------------------------------------------------+
//| Check M5 for Retest                                              |
//+------------------------------------------------------------------+
void CheckM5Retest(int symbolIndex) {
   string symbol = g_symbols[symbolIndex].name;
   
   // Check if price is in M5 EMA zone
   if(IsPriceInEMAZone(symbolIndex, TF_M5, 0)) {
      if(!g_symbols[symbolIndex].m5RetestDetected) {
         g_symbols[symbolIndex].m5RetestDetected = true;
         g_symbols[symbolIndex].m5RetestTime = TimeCurrent();
         g_symbols[symbolIndex].signalState = STATE_WAITING_M5_ENGULFING;
         
         Log(symbol + " M5 RETEST detected - Now waiting for M5 engulfing", "M5_RETEST");
      }
   }
}

//+------------------------------------------------------------------+
//| Check M5 for Engulfing Entry                                     |
//+------------------------------------------------------------------+
void CheckM5Engulfing(int symbolIndex) {
   string symbol = g_symbols[symbolIndex].name;
   
   // Only check on new M5 bar
   if(!IsNewBar(symbolIndex, TF_M5)) return;
   
   // Detect M5 engulfing
   ENGULF_TYPE engulf = DetectEngulfing(symbol, LTF_Timeframe, 1);
   
   if(engulf == ENGULF_NONE) return;
   
   // Check if engulfing matches H1 direction
   bool validEngulf = false;
   if(g_symbols[symbolIndex].h1Direction == TREND_BULLISH) {
      validEngulf = (engulf == ENGULF_SINGLE_BULLISH || engulf == ENGULF_DOUBLE_BULLISH);
   } else if(g_symbols[symbolIndex].h1Direction == TREND_BEARISH) {
      validEngulf = (engulf == ENGULF_SINGLE_BEARISH || engulf == ENGULF_DOUBLE_BEARISH);
   }
   
   if(!validEngulf) return;
   
   Log(symbol + " M5 ENGULFING detected - " + GetEngulfName(engulf), "M5_ENTRY");
   
   // Execute trade batch!
   ExecuteTradeBatch(symbolIndex);
}

//+------------------------------------------------------------------+
//| Execute Trade Batch (2 trades: 1:1 RR and 1:2 RR)                |
//+------------------------------------------------------------------+
void ExecuteTradeBatch(int symbolIndex) {
   string symbol = g_symbols[symbolIndex].name;
   int digits = g_symbols[symbolIndex].calc.GetDigits();
   bool isBuy = (g_symbols[symbolIndex].h1Direction == TREND_BULLISH);
   
   Log("==========================================", "TRADE");
   Log(">>> " + symbol + " EXECUTING TRADE BATCH " + IntegerToString(g_symbols[symbolIndex].batchCount + 1) + " <<<", "TRADE");
   
   // Check spread
   if(!g_symbols[symbolIndex].calc.IsSpreadOK()) {
      Log("Spread too high: " + DoubleToString(g_symbols[symbolIndex].calc.GetSpreadPips(), 1) + " pips - SKIPPING", "TRADE");
      return;
   }
   
   // Get entry price
   double entry = isBuy ? SymbolInfoDouble(symbol, SYMBOL_ASK) : SymbolInfoDouble(symbol, SYMBOL_BID);
   
   // Calculate SL using M5 ATR
   double atr = GetATR(g_symbols[symbolIndex].atrHandle[TF_M5], 1);
   double slDistance = atr * ATR_Multiplier;
   double spreadBuffer = g_symbols[symbolIndex].calc.ToPrice(SpreadBufferPips);
   
   double slPips = g_symbols[symbolIndex].calc.ToPips(slDistance) + SpreadBufferPips;
   
   // Apply min/max SL limits
   if(slPips < MinSLPips) slPips = MinSLPips;
   if(slPips > MaxSLPips) slPips = MaxSLPips;
   
   slDistance = g_symbols[symbolIndex].calc.ToPrice(slPips);
   
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
   
   // Calculate lot size (same for both trades)
   double lots = CalculateLotSize(symbolIndex, slPips);
   
   if(lots < g_symbols[symbolIndex].calc.GetMinLot()) {
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
   
   // Execute Trade 1 (1:1 RR)
   string comment1 = "EMA_B" + IntegerToString(g_symbols[symbolIndex].batchCount + 1) + "_T1_" + 
                     (isBuy ? "BUY" : "SELL") + "_1:" + DoubleToString(RR_Trade1, 0);
   bool success1 = false;
   
   if(isBuy) {
      success1 = trade.Buy(lots, symbol, 0, sl, tp1, comment1);
   } else {
      success1 = trade.Sell(lots, symbol, 0, sl, tp1, comment1);
   }
   
   if(success1) {
      Log("Trade 1 (1:" + DoubleToString(RR_Trade1, 0) + " RR) OPENED - Ticket: " + IntegerToString(trade.ResultOrder()), "SUCCESS");
      
      // Store trade info directly
      if(g_symbols[symbolIndex].batchCount == 0) {
         g_symbols[symbolIndex].trade1_1.ticket = trade.ResultOrder();
         g_symbols[symbolIndex].trade1_1.entryPrice = trade.ResultPrice();
         g_symbols[symbolIndex].trade1_1.sl = sl;
         g_symbols[symbolIndex].trade1_1.tp = tp1;
         g_symbols[symbolIndex].trade1_1.lots = lots;
         g_symbols[symbolIndex].trade1_1.rrRatio = RR_Trade1;
         g_symbols[symbolIndex].trade1_1.isOpen = true;
         g_symbols[symbolIndex].trade1_1.hitTP = false;
         g_symbols[symbolIndex].trade1_1.openTime = TimeCurrent();
      } else {
         g_symbols[symbolIndex].trade2_1.ticket = trade.ResultOrder();
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
   } else {
      Log("Trade 1 FAILED: " + trade.ResultRetcodeDescription(), "ERROR");
   }
   
   // Execute Trade 2 (1:2 RR)
   string comment2 = "EMA_B" + IntegerToString(g_symbols[symbolIndex].batchCount + 1) + "_T2_" + 
                     (isBuy ? "BUY" : "SELL") + "_1:" + DoubleToString(RR_Trade2, 0);
   bool success2 = false;
   
   if(isBuy) {
      success2 = trade.Buy(lots, symbol, 0, sl, tp2, comment2);
   } else {
      success2 = trade.Sell(lots, symbol, 0, sl, tp2, comment2);
   }
   
   if(success2) {
      Log("Trade 2 (1:" + DoubleToString(RR_Trade2, 0) + " RR) OPENED - Ticket: " + IntegerToString(trade.ResultOrder()), "SUCCESS");
      
      // Store trade info directly
      if(g_symbols[symbolIndex].batchCount == 0) {
         g_symbols[symbolIndex].trade1_2.ticket = trade.ResultOrder();
         g_symbols[symbolIndex].trade1_2.entryPrice = trade.ResultPrice();
         g_symbols[symbolIndex].trade1_2.sl = sl;
         g_symbols[symbolIndex].trade1_2.tp = tp2;
         g_symbols[symbolIndex].trade1_2.lots = lots;
         g_symbols[symbolIndex].trade1_2.rrRatio = RR_Trade2;
         g_symbols[symbolIndex].trade1_2.isOpen = true;
         g_symbols[symbolIndex].trade1_2.hitTP = false;
         g_symbols[symbolIndex].trade1_2.openTime = TimeCurrent();
      } else {
         g_symbols[symbolIndex].trade2_2.ticket = trade.ResultOrder();
         g_symbols[symbolIndex].trade2_2.entryPrice = trade.ResultPrice();
         g_symbols[symbolIndex].trade2_2.sl = sl;
         g_symbols[symbolIndex].trade2_2.tp = tp2;
         g_symbols[symbolIndex].trade2_2.lots = lots;
         g_symbols[symbolIndex].trade2_2.rrRatio = RR_Trade2;
         g_symbols[symbolIndex].trade2_2.isOpen = true;
         g_symbols[symbolIndex].trade2_2.hitTP = false;
         g_symbols[symbolIndex].trade2_2.openTime = TimeCurrent();
      }
      
      g_dailyTrades++;
   } else {
      Log("Trade 2 FAILED: " + trade.ResultRetcodeDescription(), "ERROR");
   }
   
   // Update batch count and state
   g_symbols[symbolIndex].batchCount++;
   
   // Update batch stats
   if(g_symbols[symbolIndex].batchCount == 1) {
      g_symbols[symbolIndex].stats.batch1Trades += 2; // 2 trades per batch
   } else {
      g_symbols[symbolIndex].stats.batch2Trades += 2;
   }
   
   if(g_symbols[symbolIndex].batchCount >= MaxBatchesPerH1Signal) {
      g_symbols[symbolIndex].signalState = STATE_SIGNAL_COMPLETE;
      Log("Max batches reached - Waiting for new H1 signal", "TRADE");
   } else {
      if(g_symbols[symbolIndex].batchCount == 1) {
         g_symbols[symbolIndex].signalState = STATE_BATCH1_ACTIVE;
      } else {
         g_symbols[symbolIndex].signalState = STATE_BATCH2_ACTIVE;
      }
   }
   
   // Reset M5 tracking for next potential batch
   g_symbols[symbolIndex].m5RetestDetected = false;
   g_symbols[symbolIndex].m5EngulfDetected = false;
   
   Log("==========================================", "TRADE");
}

//+------------------------------------------------------------------+
//| Monitor Active Trades                                            |
//+------------------------------------------------------------------+
void MonitorTrades(int symbolIndex) {
   string symbol = g_symbols[symbolIndex].name;
   
   // Check batch 1 trades
   if(g_symbols[symbolIndex].signalState == STATE_BATCH1_ACTIVE) {
      bool trade1_1_WasOpen = g_symbols[symbolIndex].trade1_1.isOpen;
      bool trade1_2_WasOpen = g_symbols[symbolIndex].trade1_2.isOpen;
      
      // Check trade 1_1 (1:1 RR)
      if(g_symbols[symbolIndex].trade1_1.isOpen && g_symbols[symbolIndex].trade1_1.ticket > 0) {
         if(!PositionSelectByTicket(g_symbols[symbolIndex].trade1_1.ticket)) {
            g_symbols[symbolIndex].trade1_1.isOpen = false;
            UpdateTradeStats(symbolIndex, g_symbols[symbolIndex].trade1_1.ticket);
            
            if(CheckIfTPHit(g_symbols[symbolIndex].trade1_1.ticket)) {
               g_symbols[symbolIndex].trade1_1.hitTP = true;
               Log(symbol + " Trade 1 (1:1 RR) HIT TP", "TP_HIT");
            } else {
               Log(symbol + " Trade 1 (1:1 RR) closed (SL or manual)", "TRADE");
            }
         }
      }
      
      // Check trade 1_2 (1:2 RR)
      if(g_symbols[symbolIndex].trade1_2.isOpen && g_symbols[symbolIndex].trade1_2.ticket > 0) {
         if(!PositionSelectByTicket(g_symbols[symbolIndex].trade1_2.ticket)) {
            g_symbols[symbolIndex].trade1_2.isOpen = false;
            UpdateTradeStats(symbolIndex, g_symbols[symbolIndex].trade1_2.ticket);
            
            if(CheckIfTPHit(g_symbols[symbolIndex].trade1_2.ticket)) {
               g_symbols[symbolIndex].trade1_2.hitTP = true;
               Log(symbol + " Trade 2 (1:2 RR) HIT TP", "TP_HIT");
            } else {
               Log(symbol + " Trade 2 (1:2 RR) closed (SL or manual)", "TRADE");
            }
         }
      }
      
      // Check if both batch 1 trades are now closed
      bool bothClosed = !g_symbols[symbolIndex].trade1_1.isOpen && !g_symbols[symbolIndex].trade1_2.isOpen;
      
      if(bothClosed) {
         // If 1:1 hit TP and we can do batch 2, wait for second retest
         if(g_symbols[symbolIndex].trade1_1.hitTP && g_symbols[symbolIndex].batchCount < MaxBatchesPerH1Signal) {
            g_symbols[symbolIndex].signalState = STATE_WAITING_M5_RETEST2;
            g_symbols[symbolIndex].m5RetestDetected = false;
            Log(symbol + " Batch 1 complete with TP - Waiting for second M5 retest...", "STATE");
         } else {
            // Both trades closed (SL or max batches reached), signal is complete
            g_symbols[symbolIndex].signalState = STATE_SIGNAL_COMPLETE;
            Log(symbol + " Batch 1 complete - Signal finished", "STATE");
         }
      }
   }
   
   // Check batch 2 trades
   if(g_symbols[symbolIndex].signalState == STATE_BATCH2_ACTIVE) {
      // Check trade 2_1
      if(g_symbols[symbolIndex].trade2_1.isOpen && g_symbols[symbolIndex].trade2_1.ticket > 0) {
         if(!PositionSelectByTicket(g_symbols[symbolIndex].trade2_1.ticket)) {
            g_symbols[symbolIndex].trade2_1.isOpen = false;
            UpdateTradeStats(symbolIndex, g_symbols[symbolIndex].trade2_1.ticket);
            Log(symbol + " Batch 2 Trade 1 closed", "TRADE");
         }
      }
      
      // Check trade 2_2
      if(g_symbols[symbolIndex].trade2_2.isOpen && g_symbols[symbolIndex].trade2_2.ticket > 0) {
         if(!PositionSelectByTicket(g_symbols[symbolIndex].trade2_2.ticket)) {
            g_symbols[symbolIndex].trade2_2.isOpen = false;
            UpdateTradeStats(symbolIndex, g_symbols[symbolIndex].trade2_2.ticket);
            Log(symbol + " Batch 2 Trade 2 closed", "TRADE");
         }
      }
      
      // Check if both batch 2 trades are closed
      if(!g_symbols[symbolIndex].trade2_1.isOpen && !g_symbols[symbolIndex].trade2_2.isOpen) {
         g_symbols[symbolIndex].signalState = STATE_SIGNAL_COMPLETE;
         Log(symbol + " Batch 2 complete - Signal finished", "STATE");
      }
   }
   
   // STATE_SIGNAL_COMPLETE: Reset immediately for new signals
   if(g_symbols[symbolIndex].signalState == STATE_SIGNAL_COMPLETE) {
      Log(symbol + " Resetting for new H1 signal", "RESET");
      ResetSymbolState(symbolIndex);
   }
}

//+------------------------------------------------------------------+
//| Update Trade Stats from Closed Trade                             |
//+------------------------------------------------------------------+
void UpdateTradeStats(int symbolIndex, ulong ticket) {
   if(ticket == 0) return;
   
   // Select history
   if(!HistorySelectByPosition(ticket)) {
      HistorySelect(TimeCurrent() - 86400 * 7, TimeCurrent()); // Last 7 days
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
   g_symbols[symbolIndex].stats.totalTrades++;
   g_symbols[symbolIndex].stats.netProfit += profit;
   
   if(profit > 0) {
      g_symbols[symbolIndex].stats.wins++;
      g_symbols[symbolIndex].stats.grossProfit += profit;
      if(profit > g_symbols[symbolIndex].stats.largestWin) {
         g_symbols[symbolIndex].stats.largestWin = profit;
      }
      Log(g_symbols[symbolIndex].name + " WIN: $" + DoubleToString(profit, 2) + 
          " | Total P/L: $" + DoubleToString(g_symbols[symbolIndex].stats.netProfit, 2), "STATS");
   } else if(profit < 0) {
      g_symbols[symbolIndex].stats.losses++;
      g_symbols[symbolIndex].stats.grossLoss += profit; // Negative value
      if(profit < g_symbols[symbolIndex].stats.largestLoss) {
         g_symbols[symbolIndex].stats.largestLoss = profit;
      }
      Log(g_symbols[symbolIndex].name + " LOSS: $" + DoubleToString(profit, 2) + 
          " | Total P/L: $" + DoubleToString(g_symbols[symbolIndex].stats.netProfit, 2), "STATS");
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
void ProcessSymbol(int symbolIndex) {
   if(!g_symbols[symbolIndex].enabled) return;
   
   string symbol = g_symbols[symbolIndex].name;
   SIGNAL_STATE state = g_symbols[symbolIndex].signalState;
   
   // Log current state periodically (every 5 minutes)
   static datetime lastStateLog[];
   static bool stateLogInit = false;
   if(!stateLogInit) {
      ArrayResize(lastStateLog, MAX_SYMBOLS);
      ArrayInitialize(lastStateLog, 0);
      stateLogInit = true;
   }
   
   if(TimeCurrent() - lastStateLog[symbolIndex] > 300) { // Every 5 minutes
      lastStateLog[symbolIndex] = TimeCurrent();
      if(state != STATE_WAITING_H1_SIGNAL) {
         Log(symbol + " Current state: " + GetStateName(state) + 
             " | Batch: " + IntegerToString(g_symbols[symbolIndex].batchCount) +
             " | H1 Signal Age: " + IntegerToString((int)((TimeCurrent() - g_symbols[symbolIndex].h1SignalTime) / 60)) + " min", "STATUS");
      }
   }
   
   // Always monitor active trades first
   MonitorTrades(symbolIndex);
   
   // Re-check state after MonitorTrades (it might have changed)
   state = g_symbols[symbolIndex].signalState;
   
   // Check signal timeout and validity (only if we have an active signal waiting)
   if(state != STATE_WAITING_H1_SIGNAL && state != STATE_SIGNAL_COMPLETE) {
      if(ShouldResetSignal(symbolIndex)) {
         Log(symbol + " Signal RESET - Timeout or invalidated", "RESET");
         ResetSymbolState(symbolIndex);
         return;
      }
   }
   
   // Re-check state again
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
         // Trades being monitored by MonitorTrades()
         break;
         
      case STATE_SIGNAL_COMPLETE:
         // Should have been reset in MonitorTrades, but just in case
         Log(symbol + " STATE_SIGNAL_COMPLETE in ProcessSymbol - forcing reset", "WARN");
         ResetSymbolState(symbolIndex);
         break;
   }
}

//+------------------------------------------------------------------+
//| Check if Signal Should Be Reset                                  |
//+------------------------------------------------------------------+
bool ShouldResetSignal(int symbolIndex) {
   string symbol = g_symbols[symbolIndex].name;
   SIGNAL_STATE state = g_symbols[symbolIndex].signalState;
   
   // FAILSAFE: If we have an active batch state but no open trades, reset immediately
   if(state == STATE_BATCH1_ACTIVE || state == STATE_BATCH2_ACTIVE) {
      bool hasOpenTrades = g_symbols[symbolIndex].trade1_1.isOpen ||
                           g_symbols[symbolIndex].trade1_2.isOpen ||
                           g_symbols[symbolIndex].trade2_1.isOpen ||
                           g_symbols[symbolIndex].trade2_2.isOpen;
      
      if(!hasOpenTrades) {
         // Double-check with actual position scan
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
            Log(symbol + " FAILSAFE: Batch state with no open trades - forcing reset", "FAILSAFE");
            return true;
         }
      }
   }
   
   // Only apply timeout checks for waiting states (not active trade states)
   if(state != STATE_WAITING_M5_RETEST && 
      state != STATE_WAITING_M5_ENGULFING &&
      state != STATE_WAITING_M5_RETEST2) {
      return false;
   }
   
   // Check signal timeout (hours)
   if(SignalTimeoutHours > 0 && g_symbols[symbolIndex].h1SignalTime > 0) {
      datetime elapsed = TimeCurrent() - g_symbols[symbolIndex].h1SignalTime;
      int hoursElapsed = (int)(elapsed / 3600);
      
      if(hoursElapsed >= SignalTimeoutHours) {
         Log(symbol + " Signal timeout: " + IntegerToString(hoursElapsed) + " hours elapsed", "TIMEOUT");
         return true;
      }
   }
   
   // Check for stale signals (too many H1 bars without entry)
   if(ResetOnNewH1Bar && g_symbols[symbolIndex].h1SignalTime > 0) {
      int barsSinceSignal = iBarShift(symbol, HTF_Timeframe, g_symbols[symbolIndex].h1SignalTime);
      
      if(barsSinceSignal >= 2) {
         Log(symbol + " Signal stale: " + IntegerToString(barsSinceSignal) + " H1 bars since signal", "STALE");
         return true;
      }
   }
   
   // Check for opposite H1 engulfing (invalidates current signal)
   if(ResetOnOppositeSignal && g_symbols[symbolIndex].batchCount == 0) {
      // Only check on new H1 bar to avoid repeated checks
      datetime currentH1Bar = iTime(symbol, HTF_Timeframe, 0);
      static datetime lastCheckBar[];
      static bool initialized = false;
      
      if(!initialized) {
         ArrayResize(lastCheckBar, MAX_SYMBOLS);
         ArrayInitialize(lastCheckBar, 0);
         initialized = true;
      }
      
      if(currentH1Bar != lastCheckBar[symbolIndex]) {
         lastCheckBar[symbolIndex] = currentH1Bar;
         
         ENGULF_TYPE currentEngulf = DetectEngulfing(symbol, HTF_Timeframe, 1);
         
         if(currentEngulf != ENGULF_NONE) {
            bool isBullish = (currentEngulf == ENGULF_SINGLE_BULLISH || currentEngulf == ENGULF_DOUBLE_BULLISH);
            bool isBearish = (currentEngulf == ENGULF_SINGLE_BEARISH || currentEngulf == ENGULF_DOUBLE_BEARISH);
            
            if((g_symbols[symbolIndex].h1Direction == TREND_BULLISH && isBearish) ||
               (g_symbols[symbolIndex].h1Direction == TREND_BEARISH && isBullish)) {
               Log(symbol + " Opposite H1 engulfing detected - invalidating signal", "INVALIDATE");
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
      
      // Reset all symbol states on new day
      for(int i = 0; i < MAX_SYMBOLS; i++) {
         if(g_symbols[i].enabled) {
            SIGNAL_STATE state = g_symbols[i].signalState;
            
            // Check if there are any actual open positions for this symbol
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
            
            // If no open positions, force reset the state machine
            if(!hasOpenPositions && state != STATE_WAITING_H1_SIGNAL) {
               Log(g_symbols[i].name + " Daily reset - State was: " + GetStateName(state) + " -> Resetting", "RESET");
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
   Log("GOLD ENGULFING BOT v3.0 Starting", "INIT");
   Log("Strategy: H1 Engulfing -> M5 Retest + Engulfing -> Dual Trade", "INIT");
   Log("Trades: 1:" + DoubleToString(RR_Trade1, 0) + " RR + 1:" + DoubleToString(RR_Trade2, 0) + " RR", "INIT");
   Log("Max Batches per H1 Signal: " + IntegerToString(MaxBatchesPerH1Signal), "INIT");
   
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(30);
   trade.SetTypeFilling(ORDER_FILLING_IOC);
   
   g_activeSymbols = 0;
   g_symbolEnabled[0] = TradeXAUUSD;
   g_symbolEnabled[1] = TradeGBPUSD;
   g_symbolEnabled[2] = TradeGBPJPY;
   g_maxSpreads[0] = MaxSpread_XAUUSD;
   g_maxSpreads[1] = MaxSpread_GBPUSD;
   g_maxSpreads[2] = MaxSpread_GBPJPY;
   
   for(int i = 0; i < MAX_SYMBOLS; i++) {
      if(!InitSymbolConfig(i, g_symbolNames[i], g_symbolEnabled[i], g_maxSpreads[i])) {
         Log("Failed to initialize " + g_symbolNames[i], "ERROR");
      }
   }
   
   if(g_activeSymbols == 0) {
      Alert("No symbols initialized!");
      return INIT_FAILED;
   }
   
   g_dailyResetTime = TimeCurrent();
   g_dailyStartBalance = account.Balance();
   
   EventSetMillisecondTimer(TimerIntervalMs);
   
   Log("Active Symbols: " + IntegerToString(g_activeSymbols), "INIT");
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
   
   // Periodic failsafe: Check for stuck states every minute
   static datetime lastFailsafeCheck = 0;
   if(TimeCurrent() - lastFailsafeCheck > 60) {
      lastFailsafeCheck = TimeCurrent();
      CheckStuckStates();
   }
   
   if(!CheckDailyLimits()) return;
   
   // Check trading session
   if(!IsTradingAllowedInSession()) {
      static datetime lastSessionLog = 0;
      if(TimeCurrent() - lastSessionLog > 3600) { // Log once per hour
         string currentSession = GetCurrentSessionName();
         string enabledSessions = "";
         if(TradeAsianSession) enabledSessions += "Asian ";
         if(TradeLondonSession) enabledSessions += "London ";
         if(TradeNewYorkSession) enabledSessions += "NY ";
         if(StringLen(enabledSessions) == 0) enabledSessions = "NONE";
         
         Log("Session Filter Active | Current: " + currentSession + 
             " | Enabled: " + enabledSessions + 
             " | GMT Hour: " + IntegerToString(GetGMTHour()), "SESSION");
         lastSessionLog = TimeCurrent();
      }
      return;
   }
   
   for(int i = 0; i < MAX_SYMBOLS; i++) {
      ProcessSymbol(i);
   }
}

//+------------------------------------------------------------------+
//| Check for Stuck States (Failsafe)                                |
//+------------------------------------------------------------------+
void CheckStuckStates() {
   for(int i = 0; i < MAX_SYMBOLS; i++) {
      if(!g_symbols[i].enabled) continue;
      
      string symbol = g_symbols[i].name;
      SIGNAL_STATE state = g_symbols[i].signalState;
      
      // Skip if waiting for H1 (normal idle state)
      if(state == STATE_WAITING_H1_SIGNAL) continue;
      
      // Check if we have any actual open positions for this symbol
      bool hasRealPositions = false;
      for(int p = PositionsTotal() - 1; p >= 0; p--) {
         ulong ticket = PositionGetTicket(p);
         if(ticket > 0 && PositionSelectByTicket(ticket)) {
            if(PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
               PositionGetString(POSITION_SYMBOL) == symbol) {
               hasRealPositions = true;
               break;
            }
         }
      }
      
      // If we're in a batch state but have no real positions, something is wrong
      if((state == STATE_BATCH1_ACTIVE || state == STATE_BATCH2_ACTIVE) && !hasRealPositions) {
         Log(symbol + " STUCK STATE DETECTED: " + GetStateName(state) + " with no positions - Resetting", "FAILSAFE");
         ResetSymbolState(i);
         continue;
      }
      
      // If waiting states have been active too long (12+ hours without trade), force reset
      if(state == STATE_WAITING_M5_RETEST || 
         state == STATE_WAITING_M5_ENGULFING ||
         state == STATE_WAITING_M5_RETEST2 ||
         state == STATE_SIGNAL_COMPLETE) {
         
         if(g_symbols[i].h1SignalTime > 0) {
            int hoursStuck = (int)((TimeCurrent() - g_symbols[i].h1SignalTime) / 3600);
            if(hoursStuck >= 12) {
               Log(symbol + " STUCK STATE DETECTED: " + GetStateName(state) + 
                   " for " + IntegerToString(hoursStuck) + " hours - Resetting", "FAILSAFE");
               ResetSymbolState(i);
            }
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
   
   // Print comprehensive statistics
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
   
   Log("Bot stopped. Daily trades: " + IntegerToString(g_dailyTrades), "DEINIT");
}

//+------------------------------------------------------------------+
//| Print Trade Statistics                                           |
//+------------------------------------------------------------------+
void PrintTradeStatistics() {
   Print("");
   Print("╔════════════════════════════════════════════════════════════════════════════════╗");
   Print("║                        GOLD ENGULFING BOT - TRADE STATISTICS                   ║");
   Print("╠════════════════════════════════════════════════════════════════════════════════╣");
   
   // Overall totals
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
   double overallPF = totalGrossLoss != 0 ? totalGrossProfit / MathAbs(totalGrossLoss) : 0;
   
   PrintFormat("║ OVERALL: Trades: %d | Wins: %d | Losses: %d | Win Rate: %.1f%%                    ║", 
               totalTrades, totalWins, totalLosses, overallWinRate);
   PrintFormat("║ Net Profit: $%.2f | Profit Factor: %.2f | H1 Signals: %d                    ║",
               totalProfit, overallPF, totalH1Signals);
   Print("╠════════════════════════════════════════════════════════════════════════════════╣");
   Print("║                              PER-SYMBOL BREAKDOWN                              ║");
   Print("╠══════════════╦════════╦══════╦════════╦══════════╦═══════════╦═════════════════╣");
   Print("║    SYMBOL    ║ TRADES ║ WINS ║ LOSSES ║ WIN RATE ║ NET P/L   ║ PROFIT FACTOR   ║");
   Print("╠══════════════╬════════╬══════╬════════╬══════════╬═══════════╬═════════════════╣");
   
   for(int i = 0; i < MAX_SYMBOLS; i++) {
      if(!g_symbols[i].enabled) continue;
      
      SymbolStats stats = g_symbols[i].stats;
      
      PrintFormat("║ %-12s ║ %6d ║ %4d ║ %6d ║ %7.1f%% ║ %+9.2f ║ %14.2f  ║",
                  g_symbols[i].name,
                  stats.totalTrades,
                  stats.wins,
                  stats.losses,
                  stats.WinRate(),
                  stats.netProfit,
                  stats.ProfitFactor());
   }
   
   Print("╠══════════════╩════════╩══════╩════════╩══════════╩═══════════╩═════════════════╣");
   Print("║                              DETAILED STATISTICS                               ║");
   Print("╠══════════════╦══════════╦══════════╦══════════╦══════════╦═════════════════════╣");
   Print("║    SYMBOL    ║  AVG WIN ║ AVG LOSS ║ BEST WIN ║WORST LOSS║    EXPECTANCY       ║");
   Print("╠══════════════╬══════════╬══════════╬══════════╬══════════╬═════════════════════╣");
   
   for(int i = 0; i < MAX_SYMBOLS; i++) {
      if(!g_symbols[i].enabled) continue;
      
      SymbolStats stats = g_symbols[i].stats;
      
      PrintFormat("║ %-12s ║ %8.2f ║ %8.2f ║ %8.2f ║ %8.2f ║ %19.2f ║",
                  g_symbols[i].name,
                  stats.AvgWin(),
                  stats.AvgLoss(),
                  stats.largestWin,
                  stats.largestLoss,
                  stats.Expectancy());
   }
   
   Print("╠══════════════╩══════════╩══════════╩══════════╩══════════╩═════════════════════╣");
   Print("║                              SIGNAL STATISTICS                                 ║");
   Print("╠══════════════╦═════════════╦═════════════╦═════════════════════════════════════╣");
   Print("║    SYMBOL    ║ H1 SIGNALS  ║ BATCH1 TRDS ║ BATCH2 TRDS                         ║");
   Print("╠══════════════╬═════════════╬═════════════╬═════════════════════════════════════╣");
   
   for(int i = 0; i < MAX_SYMBOLS; i++) {
      if(!g_symbols[i].enabled) continue;
      
      SymbolStats stats = g_symbols[i].stats;
      
      PrintFormat("║ %-12s ║ %11d ║ %11d ║ %11d                         ║",
                  g_symbols[i].name,
                  stats.h1SignalsDetected,
                  stats.batch1Trades,
                  stats.batch2Trades);
   }
   
   Print("╚══════════════╩═════════════╩═════════════╩═════════════════════════════════════╝");
   Print("");
}
//+------------------------------------------------------------------+