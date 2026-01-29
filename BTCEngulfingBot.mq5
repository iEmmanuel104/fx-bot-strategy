//+------------------------------------------------------------------+
//|                                           BTCEngulfingBot.mq5    |
//|                        EMA Crossover & Retest Bitcoin-Only EA    |
//|                                                       Version 1.0|
//|                    SIGNAL BROADCAST MODE - For Multi-Account Use |
//|  Supports: BTCUSD (Bitcoin) ONLY                                 |
//|  Strategy: H1 Engulfing + EMA -> M5 Retest + Engulfing -> Entry  |
//|  Features: Dual Trade (1:1 + 1:2 RR), ATR-based SL, 2 Batches    |
//+------------------------------------------------------------------+
#property copyright "FXBot Trading"
#property link      "https://fxbot.trading"
#property version   "1.00"
#property strict
#property description "Bitcoin-Only EMA 10/23 Engulfing Strategy v1.0"
#property description "Based on GoldEngulfingBot v7 - Adapted for BTC volatility"
#property description "H1: Engulfing candle closes above/below EMA lines"
#property description "M5: Wait for EMA retest + Engulfing confirmation"
#property description "Entry: Dual trades (1:1 RR + 1:2 RR)"
#property description "Max 2 batches per H1 signal"

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
input string   BroadcastAPIKey = "b80f66634faa378831fe572fe9e2ae326ef5daec11a0e56711d9281202e1eea1"; // Broadcast API Key
input bool     ExecuteOnMaster = true;                    // Also execute trades on THIS account

input group "=== Server Configuration ==="
input string   ServerURL = "https://fxbot-server-production.up.railway.app/api";
input int      MagicNumber = 347891;                      // Magic Number (different from Gold)
input bool     EnableServerConnection = true;             // Connect to server
input int      HeartbeatIntervalSec = 30;                 // Heartbeat interval (seconds)

input group "=== Risk Management ==="
input bool     UsePercentageRisk = true;                  // TRUE = % of balance | FALSE = Fixed $
input double   RiskPercent = 0.5;                         // Risk per trade (lower for BTC volatility)
input double   RiskDollars = 50.0;                        // Fixed dollar risk per trade
input double   MinRiskPercent = 0.5;                      // MINIMUM risk % floor
input double   MaxRiskPercent = 2.0;                      // MAXIMUM risk % ceiling
input double   RR_Trade1 = 1.0;                           // Risk:Reward for Trade 1
input double   RR_Trade2 = 2.0;                           // Risk:Reward for Trade 2
input bool     AutoBreakeven = true;                      // Auto-breakeven Trade 2 when Trade 1 hits TP
input int      BreakevenBufferPips = 20;                  // Breakeven buffer in pips (larger for BTC)

input group "=== ATR Stop Loss Settings ==="
input int      ATR_Period = 14;                           // ATR Period for SL calculation
input double   ATR_Multiplier = 1.0;                      // ATR Multiplier for SL (lower - BTC ATR is huge)
input int      SpreadBufferPips = 20;                     // Additional spread buffer (pips) - larger for BTC
input int      MinSLPips = 50;                            // Minimum SL (pips) - 50 pips = $50 for BTC
input int      MaxSLPips = 500;                           // Maximum SL (pips) - 500 pips = $500 for BTC

input group "=== BTC Settings ==="
input double   MaxSpread_BTCUSD = 100.0;                  // Max spread for Bitcoin (pips) - wider spreads

input group "=== Trade Batch Settings ==="
input int      MaxBatchesPerH1Signal = 2;                 // Max trade batches per H1 signal
input int      SignalTimeoutHours = 4;                    // Reset signal if no trade within X hours (0=disabled)
input bool     ResetOnNewH1Bar = true;                    // Reset if new H1 bar and no trades taken
input bool     ResetOnOppositeSignal = true;              // Reset if opposite H1 engulfing detected

input group "=== Session Settings ==="
input bool     EnableSessionFilter = false;               // Enable session filter (FALSE = 24/7 for crypto)
input int      BrokerGMTOffset = 2;                       // Broker GMT offset

input group "=== Asian Session ==="
input bool     TradeAsianSession = true;                  // Trade during Asian session (crypto trades 24/7)
input int      AsianStartHour = 0;                        // Asian session start (GMT)
input int      AsianEndHour = 7;                          // Asian session end (GMT)

input group "=== London Session ==="
input bool     TradeLondonSession = true;                 // Trade during London session
input int      LondonStartHour = 7;                       // London session start (GMT)
input int      LondonEndHour = 16;                        // London session end (GMT)

input group "=== New York Session ==="
input bool     TradeNewYorkSession = true;                // Trade during New York session
input int      NewYorkStartHour = 13;                     // New York session start (GMT)
input int      NewYorkEndHour = 22;                       // New York session end (GMT)

input group "=== Daily Limits ==="
input int      MaxTradesPerDay = 4;                       // Max individual trades/day (0=unlimited)
input double   MaxDailyLossPercent = 5.0;                 // Max daily loss %
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
//| BTC Symbol Calculator Class                                       |
//+------------------------------------------------------------------+
class CBTCCalculator {
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

      // BTC-specific pip size: 1.0 ($1.00 increments)
      m_pipSize = 1.0;

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

   // BTC: 1 pip = $1.00 price move, 1 lot = 1 BTC
   // So: 1.0 * 1 = $1 per pip per lot
   double GetFallbackPipValue(double lots) {
      return 1.0 * lots;
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
   ulong    ticket;          // Order ticket (for display/logging)
   ulong    positionId;      // Position identifier (for history lookup)
   double   entryPrice;
   double   sl;
   double   tp;
   double   lots;
   double   rrRatio;
   bool     isOpen;
   bool     hitTP;
   bool     breakevenSet;    // Track if breakeven already applied
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
      int totalBatch1 = batch1Trades / 2;
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

CBTCCalculator g_btcCalc;
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
//| Validate Server Response                                          |
//+------------------------------------------------------------------+
bool ValidateServerResponse(char &result[], string context) {
   if(ArraySize(result) == 0) {
      Log(context + " - Empty response from server", "WARN");
      return true;
   }

   string response = CharArrayToString(result);

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

   if(StringFind(response, "AUTH_FAILED") >= 0) {
      Log(context + " - Authentication failed! Check API key", "ERROR");
      return false;
   }

   if(StringFind(response, "INVALID") >= 0) {
      Log(context + " - Invalid request: " + response, "ERROR");
      return false;
   }

   Log(context + " - Server response: " + StringSubstr(response, 0, 100), "DEBUG");
   return true;
}

//+------------------------------------------------------------------+
//| Broadcast Signal to Server with Retry Logic                        |
//+------------------------------------------------------------------+
bool BroadcastSignalToServer(string action, string symbol, double entry,
                              double sl, double tp, double tp2, string pattern, double lots) {
   if(!BroadcastMode || g_isOptimization) return true;

   // BTC trades 24/7 - no session blocking for crypto
   // (Asian session blocking removed for crypto)

   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   string url = BroadcastURL + "?api_key=" + BroadcastAPIKey +
                "&action=" + action +
                "&symbol=" + symbol +
                "&entry=" + DoubleToString(entry, digits) +
                "&sl=" + DoubleToString(sl, digits) +
                "&tp=" + DoubleToString(tp, digits) +
                "&tp2=" + DoubleToString(tp2, digits) +
                "&risk=" + DoubleToString(RiskPercent, 1) +
                "&pattern=" + pattern;

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   url += "&balance=" + DoubleToString(balance, 2);
   url += "&equity=" + DoubleToString(equity, 2);

   string headers = "Content-Type: application/x-www-form-urlencoded\r\n";

   int maxRetries = 3;
   int delays[] = {1000, 3000, 5000};

   for(int attempt = 0; attempt < maxRetries; attempt++) {
      char post[], result[];
      string resultHeaders;

      ResetLastError();
      int res = WebRequest("POST", url, headers, 5000, post, result, resultHeaders);

      if(res == 200 || res == 201) {
         ValidateServerResponse(result, symbol + " " + action);
         Log("Signal broadcast SUCCESS: " + symbol + " " + action +
             (attempt > 0 ? " (attempt " + IntegerToString(attempt + 1) + ")" : ""), "BROADCAST");
         return true;
      }

      if(res == -1) {
         int error = GetLastError();
         if(error == 4014) {
            Log("Signal broadcast FAILED: WebRequest not allowed - Add server URL to MT5 allowed URLs", "ERROR");
            return false;
         }
         Log("Signal broadcast attempt " + IntegerToString(attempt + 1) +
             " FAILED: Error " + IntegerToString(error), "WARN");
      } else {
         Log("Signal broadcast attempt " + IntegerToString(attempt + 1) +
             " FAILED: HTTP " + IntegerToString(res), "WARN");
      }

      if(attempt < maxRetries - 1) {
         Log("Retrying in " + IntegerToString(delays[attempt]) + "ms...", "INFO");
         Sleep(delays[attempt]);
      }
   }

   Log("Signal broadcast FAILED after " + IntegerToString(maxRetries) + " attempts: " + symbol + " " + action, "ERROR");
   return false;
}

//+------------------------------------------------------------------+
//| Broadcast Trade Close to Server                                    |
//+------------------------------------------------------------------+
void BroadcastTradeClose(string symbol, string action, double entry, double closePrice,
                          double profit, string reason) {
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
                "&source=BTCEngulfingBot";

   string headers = "Content-Type: application/x-www-form-urlencoded\r\n";

   int maxRetries = 3;
   int delays[] = {1000, 3000, 5000};

   for(int attempt = 0; attempt < maxRetries; attempt++) {
      char post[], result[];
      string resultHeaders;

      ResetLastError();
      int res = WebRequest("POST", url, headers, 5000, post, result, resultHeaders);

      if(res == 200 || res == 201) {
         Log("Trade close broadcast SUCCESS: " + symbol + " " + reason + " $" + DoubleToString(profit, 2), "BROADCAST");
         return;
      }

      if(res == -1) {
         int error = GetLastError();
         if(error == 4014) {
            Log("Trade close broadcast FAILED: WebRequest not allowed", "ERROR");
            return;
         }
      }

      if(attempt < maxRetries - 1) {
         Sleep(delays[attempt]);
      }
   }

   Log("Trade close broadcast FAILED after " + IntegerToString(maxRetries) + " attempts: " + symbol, "ERROR");
}

//+------------------------------------------------------------------+
//| Broadcast TP Hit to Server                                        |
//+------------------------------------------------------------------+
void BroadcastTPHit(string symbol, string action, int tpNumber, double entryPrice,
                    double tpPrice, double profit) {
   if(!BroadcastMode || g_isOptimization) return;

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
                "&source=BTCEngulfingBot";

   string headers = "Content-Type: application/x-www-form-urlencoded\r\n";

   int maxRetries = 3;
   int delays[] = {1000, 3000, 5000};

   for(int attempt = 0; attempt < maxRetries; attempt++) {
      char post[], result[];
      string resultHeaders;

      ResetLastError();
      int res = WebRequest("POST", url, headers, 5000, post, result, resultHeaders);

      if(res == 200 || res == 201) {
         Log("TP" + IntegerToString(tpNumber) + " hit broadcast SUCCESS: " + symbol, "BROADCAST");
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
//| Broadcast Breakeven to Server                                     |
//+------------------------------------------------------------------+
void BroadcastBreakeven(string symbol, string action, double entryPrice) {
   if(!BroadcastMode || g_isOptimization) return;

   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   string baseUrl = StringSubstr(BroadcastURL, 0, StringFind(BroadcastURL, "/ea"));
   string url = baseUrl + "/ea/breakeven" +
                "?api_key=" + BroadcastAPIKey +
                "&symbol=" + symbol +
                "&direction=" + action +
                "&entry=" + DoubleToString(entryPrice, digits) +
                "&source=BTCEngulfingBot";

   string headers = "Content-Type: application/x-www-form-urlencoded\r\n";

   int maxRetries = 3;
   int delays[] = {1000, 3000, 5000};

   for(int attempt = 0; attempt < maxRetries; attempt++) {
      char post[], result[];
      string resultHeaders;

      ResetLastError();
      int res = WebRequest("POST", url, headers, 5000, post, result, resultHeaders);

      if(res == 200 || res == 201) {
         Log("Breakeven broadcast SUCCESS: " + symbol, "BROADCAST");
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
//| Check if Currently in Asian Session                               |
//| For BTC: Returns false if TradeAsianSession is true (24/7 crypto)|
//+------------------------------------------------------------------+
bool IsAsianSession() {
   // BTC trades 24/7 - if Asian trading is enabled, don't block
   if(TradeAsianSession) return false;

   int gmtHour = GetGMTHour();
   return IsHourInSession(gmtHour, AsianStartHour, AsianEndHour);
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
   if(!EnableSessionFilter) return true;  // BTC default: 24/7

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
   double pipValuePerLot = g_btcCalc.GetPipValueForLots(1.0);

   if(pipValuePerLot <= 0) pipValuePerLot = g_btcCalc.GetFallbackPipValue(1.0);

   double rawLots = riskAmount / (slPips * pipValuePerLot);
   double lots = g_btcCalc.NormalizeLots(rawLots);

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
   ENUM_TIMEFRAMES tf = (tfIndex == TF_H1) ? HTF_TIMEFRAME : LTF_TIMEFRAME;
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

   double close = iClose(g_symbol, HTF_TIMEFRAME, barIndex);
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
   ENUM_TIMEFRAMES tf = (tfIndex == TF_H1) ? HTF_TIMEFRAME : LTF_TIMEFRAME;
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

   g_emaFastVisual = iMA(g_symbol, tf, EMA_FAST_PERIOD, 0, MODE_EMA, EMA_APPLIED_PRICE);
   if(g_emaFastVisual != INVALID_HANDLE) {
      ChartIndicatorAdd(chartId, 0, g_emaFastVisual);
   }

   g_emaSlowVisual = iMA(g_symbol, tf, EMA_SLOW_PERIOD, 0, MODE_EMA, EMA_APPLIED_PRICE);
   if(g_emaSlowVisual != INVALID_HANDLE) {
      ChartIndicatorAdd(chartId, 0, g_emaSlowVisual);
   }

   Log("Visual EMAs added: EMA " + IntegerToString(EMA_FAST_PERIOD) + " & EMA " + IntegerToString(EMA_SLOW_PERIOD), "INIT");
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
//| Initialize BTC Symbol                                            |
//+------------------------------------------------------------------+
bool InitBTCSymbol() {
   string symbolName = "BTCUSD";
   string actualSymbol = symbolName;

   Print("InitBTCSymbol: Starting symbol search...");

   if(!SymbolSelect(symbolName, true)) {
      Print("Primary symbol BTCUSD not found, searching variations...");
      string btcVariations[] = {
         "BTCUSD", "BTCUSD.s", "BTCUSD.pro", "BTCUSD.ecn", "BTCUSD.raw",
         "BTCUSDm", "BTCUSDc", "BTCUSD-", "BTCUSD_", "BTCUSD#",
         "BTC", "BTCm", "Bitcoin", "BITCOIN", "XBTUSD"
      };
      bool found = false;

      for(int g = 0; g < ArraySize(btcVariations) && !found; g++) {
         string testSymbol = btcVariations[g];
         if(SymbolSelect(testSymbol, true)) {
            Print("FOUND BTC symbol: ", testSymbol);
            actualSymbol = testSymbol;
            found = true;
         }
      }

      if(!found) {
         Log("BTC symbol not available - tried all variations", "ERROR");
         Print("BTC symbol search FAILED - no valid symbol found");
         return false;
      }
   } else {
      Print("Primary symbol BTCUSD found directly");
   }

   if(!g_btcCalc.Init(actualSymbol, MaxSpread_BTCUSD)) {
      Log("Failed to initialize calculator for " + actualSymbol, "ERROR");
      return false;
   }

   g_symbol = actualSymbol;
   g_symbolEnabled = true;

   // Create indicator handles
   g_emaFastHandle[TF_H1] = iMA(actualSymbol, HTF_TIMEFRAME, EMA_FAST_PERIOD, 0, MODE_EMA, EMA_APPLIED_PRICE);
   g_emaSlowHandle[TF_H1] = iMA(actualSymbol, HTF_TIMEFRAME, EMA_SLOW_PERIOD, 0, MODE_EMA, EMA_APPLIED_PRICE);
   g_atrHandle[TF_H1] = iATR(actualSymbol, HTF_TIMEFRAME, ATR_Period);

   g_emaFastHandle[TF_M5] = iMA(actualSymbol, LTF_TIMEFRAME, EMA_FAST_PERIOD, 0, MODE_EMA, EMA_APPLIED_PRICE);
   g_emaSlowHandle[TF_M5] = iMA(actualSymbol, LTF_TIMEFRAME, EMA_SLOW_PERIOD, 0, MODE_EMA, EMA_APPLIED_PRICE);
   g_atrHandle[TF_M5] = iATR(actualSymbol, LTF_TIMEFRAME, ATR_Period);

   if(g_emaFastHandle[TF_H1] == INVALID_HANDLE ||
      g_emaSlowHandle[TF_H1] == INVALID_HANDLE ||
      g_emaFastHandle[TF_M5] == INVALID_HANDLE ||
      g_emaSlowHandle[TF_M5] == INVALID_HANDLE ||
      g_atrHandle[TF_H1] == INVALID_HANDLE ||
      g_atrHandle[TF_M5] == INVALID_HANDLE) {
      Log("Failed to create indicators for " + actualSymbol, "ERROR");
      g_symbolEnabled = false;
      return false;
   }

   AddVisualEMAs();
   ResetState();

   // Log pip value calculation for verification
   double testPipValue = g_btcCalc.GetPipValueForLots(1.0);
   Log("Initialized " + actualSymbol +
       " | PipSize: " + DoubleToString(g_btcCalc.GetPipSize(), 5) +
       " | PipValue: $" + DoubleToString(testPipValue, 2) + "/lot" +
       " | Digits: " + IntegerToString(g_btcCalc.GetDigits()), "INIT");

   // Warn if pip value seems off (should be around $1 for BTC)
   if(testPipValue < 0.5 || testPipValue > 2.0) {
      Log("WARNING: BTC pip value ($" + DoubleToString(testPipValue, 2) +
          ") outside expected range ($0.50-$2.00). Using fallback $1/lot.", "WARN");
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

   g_lastH1BarCheck = TimeCurrent();
   g_h1BarsAnalyzed++;

   if(g_signalState != STATE_WAITING_H1_SIGNAL) {
      g_lastH1Result = "State: " + GetStateName(g_signalState);
      Log("[H1 BAR #" + IntegerToString(g_h1BarsAnalyzed) + "] Skipped - Already have signal", "H1_CHECK");
      return;
   }

   ENGULF_TYPE engulf = DetectEngulfing(g_symbol, HTF_TIMEFRAME, 1);

   if(engulf == ENGULF_NONE) {
      g_lastH1Result = "No engulfing pattern";
      Log("[H1 BAR #" + IntegerToString(g_h1BarsAnalyzed) + "] Checked - No engulfing pattern", "H1_CHECK");
      return;
   }

   TREND_STATE h1EmaTrend = GetEMATrend(g_emaFastHandle[TF_H1], g_emaSlowHandle[TF_H1], 1);

   if(h1EmaTrend == TREND_NONE) {
      g_lastH1Result = GetEngulfName(engulf) + " - EMA trend unclear";
      Log("[H1 BAR #" + IntegerToString(g_h1BarsAnalyzed) + "] Found " + GetEngulfName(engulf) + " but EMA unclear", "H1_CHECK");
      return;
   }

   bool engulfMatchesTrend = false;
   if(h1EmaTrend == TREND_BULLISH && (engulf == ENGULF_SINGLE_BULLISH || engulf == ENGULF_DOUBLE_BULLISH)) {
      engulfMatchesTrend = true;
   } else if(h1EmaTrend == TREND_BEARISH && (engulf == ENGULF_SINGLE_BEARISH || engulf == ENGULF_DOUBLE_BEARISH)) {
      engulfMatchesTrend = true;
   }

   if(!engulfMatchesTrend) {
      g_lastH1Result = GetEngulfName(engulf) + " - Against EMA trend";
      Log("[H1 BAR #" + IntegerToString(g_h1BarsAnalyzed) + "] Found " + GetEngulfName(engulf) + " but wrong direction", "H1_CHECK");
      return;
   }

   Log("[H1 BAR #" + IntegerToString(g_h1BarsAnalyzed) + "] " + GetEngulfName(engulf) +
       " matches EMA trend - Checking EMA position", "H1_CHECK");

   if(!CheckEngulfingAboveBelowEMA(engulf, 1)) {
      if(!IsPriceInEMAZone(TF_H1, 1)) {
         g_lastH1Result = GetEngulfName(engulf) + " - Not at EMA";
         Log("[H1 BAR #" + IntegerToString(g_h1BarsAnalyzed) + "] Found engulf but NOT at EMA zone", "H1_CHECK");
         return;
      }
   }

   g_h1EngulfType = engulf;
   g_h1SignalTime = iTime(g_symbol, HTF_TIMEFRAME, 1);
   g_h1SignalPrice = iClose(g_symbol, HTF_TIMEFRAME, 1);

   if(engulf == ENGULF_SINGLE_BULLISH || engulf == ENGULF_DOUBLE_BULLISH) {
      g_h1Direction = TREND_BULLISH;
   } else {
      g_h1Direction = TREND_BEARISH;
   }

   g_signalState = STATE_WAITING_M5_RETEST;
   g_m5RetestDetected = false;
   g_m5EngulfDetected = false;

   g_stats.h1SignalsDetected++;
   g_lastH1Result = ">>> " + (g_h1Direction == TREND_BULLISH ? "BUY" : "SELL") + " SIGNAL <<<";

   Log("========================================", "H1_SIGNAL");
   Log("[H1 BAR #" + IntegerToString(g_h1BarsAnalyzed) + "] >>> H1 SIGNAL DETECTED <<<", "H1_SIGNAL");
   Log("Type: " + GetEngulfName(engulf), "H1_SIGNAL");
   Log("Direction: " + (g_h1Direction == TREND_BULLISH ? "BULLISH" : "BEARISH"), "H1_SIGNAL");
   Log("Price: " + DoubleToString(g_h1SignalPrice, g_btcCalc.GetDigits()), "H1_SIGNAL");
   Log("Now waiting for M5 retest...", "H1_SIGNAL");
   Log("========================================", "H1_SIGNAL");
}

//+------------------------------------------------------------------+
//| Check M5 for Retest                                              |
//+------------------------------------------------------------------+
void CheckM5Retest() {
   static datetime lastM5Bar = 0;
   datetime currentM5Bar = iTime(g_symbol, LTF_TIMEFRAME, 0);

   if(currentM5Bar != lastM5Bar) {
      lastM5Bar = currentM5Bar;
      g_lastM5BarCheck = TimeCurrent();
      g_m5BarsAnalyzed++;

      TREND_STATE m5EmaTrend = GetEMATrend(g_emaFastHandle[TF_M5], g_emaSlowHandle[TF_M5], 0);

      if(m5EmaTrend != g_h1Direction) {
         g_lastM5Result = "M5 EMA mismatch - INVALIDATED";
         Log("[M5 BAR #" + IntegerToString(g_m5BarsAnalyzed) + "] M5 EMA doesn't match H1 - SIGNAL INVALIDATED", "M5_CHECK");
         ResetState();
         return;
      }

      g_lastM5Result = "EMA aligned - Waiting for retest...";
      Log("[M5 BAR #" + IntegerToString(g_m5BarsAnalyzed) + "] M5 EMA aligned - Checking for retest", "M5_CHECK");
   }

   if(IsPriceInEMAZone(TF_M5, 0)) {
      if(!g_m5RetestDetected) {
         g_m5RetestDetected = true;
         g_m5RetestTime = TimeCurrent();
         g_signalState = STATE_WAITING_M5_ENGULFING;

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

   g_lastM5BarCheck = TimeCurrent();
   g_m5BarsAnalyzed++;

   ENGULF_TYPE engulf = DetectEngulfing(g_symbol, LTF_TIMEFRAME, 1);

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
      Log("[M5 BAR #" + IntegerToString(g_m5BarsAnalyzed) + "] Found " + GetEngulfName(engulf) + " but wrong direction", "M5_CHECK");
      return;
   }

   TREND_STATE m5EmaTrend = GetEMATrend(g_emaFastHandle[TF_M5], g_emaSlowHandle[TF_M5], 1);

   if(m5EmaTrend != g_h1Direction) {
      g_lastM5Result = GetEngulfName(engulf) + " - M5 EMA misaligned";
      Log("[M5 BAR #" + IntegerToString(g_m5BarsAnalyzed) + "] Valid engulfing but M5 EMA misaligned - INVALIDATED", "M5_CHECK");
      ResetState();
      return;
   }

   g_lastM5Result = ">>> " + GetEngulfName(engulf) + " - ENTRY <<<";

   Log("[M5 BAR #" + IntegerToString(g_m5BarsAnalyzed) + "] >>> M5 ENGULFING DETECTED <<<", "M5_ENTRY");
   Log("Type: " + GetEngulfName(engulf) + " | M5 EMA: " + GetTrendName(m5EmaTrend), "M5_ENTRY");

   ExecuteTradeBatch();
}

//+------------------------------------------------------------------+
//| Get Position Identifier after trade execution                     |
//+------------------------------------------------------------------+
ulong GetPositionIdentifier(ulong orderTicket) {
   if(orderTicket == 0) return 0;

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

   Log("Warning: Could not get POSITION_IDENTIFIER for order " + IntegerToString(orderTicket), "WARN");
   return orderTicket;
}

//+------------------------------------------------------------------+
//| Execute Trade Batch (2 trades: 1:1 RR and 1:2 RR)                |
//+------------------------------------------------------------------+
void ExecuteTradeBatch() {
   int digits = g_btcCalc.GetDigits();
   bool isBuy = (g_h1Direction == TREND_BULLISH);

   Log("==========================================", "TRADE");
   Log(">>> " + g_symbol + " EXECUTING TRADE BATCH " + IntegerToString(g_batchCount + 1) + " <<<", "TRADE");

   if(!g_btcCalc.IsSpreadOK()) {
      Log("Spread too high: " + DoubleToString(g_btcCalc.GetSpreadPips(), 1) + " pips - SKIPPING", "TRADE");
      return;
   }

   double entry = isBuy ? SymbolInfoDouble(g_symbol, SYMBOL_ASK) : SymbolInfoDouble(g_symbol, SYMBOL_BID);

   double atr = GetATR(g_atrHandle[TF_M5], 1);
   double slDistance = atr * ATR_Multiplier;

   double slPips = g_btcCalc.ToPips(slDistance) + SpreadBufferPips;

   if(slPips < MinSLPips) slPips = MinSLPips;
   if(slPips > MaxSLPips) slPips = MaxSLPips;

   slDistance = g_btcCalc.ToPrice(slPips);

   double sl;
   if(isBuy) {
      sl = entry - slDistance;
   } else {
      sl = entry + slDistance;
   }

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

   double lots = CalculateLotSize(slPips);

   if(lots < g_btcCalc.GetMinLot()) {
      Log("Lot size too small - SKIPPING", "TRADE");
      return;
   }

   Log("Entry: " + DoubleToString(entry, digits), "TRADE");
   Log("SL: " + DoubleToString(sl, digits) + " (" + DoubleToString(slPips, 1) + " pips)", "TRADE");
   Log("TP1: " + DoubleToString(tp1, digits), "TRADE");
   Log("TP2: " + DoubleToString(tp2, digits), "TRADE");
   Log("Lots: " + DoubleToString(lots, 2) + " per trade", "TRADE");

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(30);

   bool success1 = false;
   bool success2 = false;

   // Execute Trade 1 (1:1 RR)
   string comment1 = "BTC_B" + IntegerToString(g_batchCount + 1) + "_T1_" +
                     (isBuy ? "BUY" : "SELL") + "_1:" + DoubleToString(RR_Trade1, 0);

   if(isBuy) {
      success1 = trade.Buy(lots, g_symbol, 0, sl, tp1, comment1);
   } else {
      success1 = trade.Sell(lots, g_symbol, 0, sl, tp1, comment1);
   }

   if(success1) {
      ulong orderTicket1 = trade.ResultOrder();
      ulong posId1 = GetPositionIdentifier(orderTicket1);
      Log("Trade 1 (1:" + DoubleToString(RR_Trade1, 0) + " RR) OPENED - Ticket: " + IntegerToString(orderTicket1), "SUCCESS");

      if(g_batchCount == 0) {
         g_trade1_1.ticket = orderTicket1;
         g_trade1_1.positionId = posId1;
         g_trade1_1.entryPrice = trade.ResultPrice();
         g_trade1_1.sl = sl;
         g_trade1_1.tp = tp1;
         g_trade1_1.lots = lots;
         g_trade1_1.rrRatio = RR_Trade1;
         g_trade1_1.isOpen = true;
         g_trade1_1.hitTP = false;
         g_trade1_1.openTime = TimeCurrent();
      } else {
         g_trade2_1.ticket = orderTicket1;
         g_trade2_1.positionId = posId1;
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
   string comment2 = "BTC_B" + IntegerToString(g_batchCount + 1) + "_T2_" +
                     (isBuy ? "BUY" : "SELL") + "_1:" + DoubleToString(RR_Trade2, 0);

   if(isBuy) {
      success2 = trade.Buy(lots, g_symbol, 0, sl, tp2, comment2);
   } else {
      success2 = trade.Sell(lots, g_symbol, 0, sl, tp2, comment2);
   }

   if(success2) {
      ulong orderTicket2 = trade.ResultOrder();
      ulong posId2 = GetPositionIdentifier(orderTicket2);
      Log("Trade 2 (1:" + DoubleToString(RR_Trade2, 0) + " RR) OPENED - Ticket: " + IntegerToString(orderTicket2), "SUCCESS");

      if(g_batchCount == 0) {
         g_trade1_2.ticket = orderTicket2;
         g_trade1_2.positionId = posId2;
         g_trade1_2.entryPrice = trade.ResultPrice();
         g_trade1_2.sl = sl;
         g_trade1_2.tp = tp2;
         g_trade1_2.lots = lots;
         g_trade1_2.rrRatio = RR_Trade2;
         g_trade1_2.isOpen = true;
         g_trade1_2.hitTP = false;
         g_trade1_2.breakevenSet = false;
         g_trade1_2.openTime = TimeCurrent();
      } else {
         g_trade2_2.ticket = orderTicket2;
         g_trade2_2.positionId = posId2;
         g_trade2_2.entryPrice = trade.ResultPrice();
         g_trade2_2.sl = sl;
         g_trade2_2.tp = tp2;
         g_trade2_2.lots = lots;
         g_trade2_2.rrRatio = RR_Trade2;
         g_trade2_2.isOpen = true;
         g_trade2_2.hitTP = false;
         g_trade2_2.breakevenSet = false;
         g_trade2_2.openTime = TimeCurrent();
      }

      g_dailyTrades++;
   } else {
      Log("Trade 2 FAILED: " + trade.ResultRetcodeDescription(), "ERROR");
   }

   if(success1 || success2) {
      g_batchCount++;
      g_stats.h1SignalsTraded++;

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

   g_m5RetestDetected = false;
   g_m5EngulfDetected = false;

   Log("==========================================", "TRADE");

   if(success1 || success2) {
      string action = isBuy ? "BUY" : "SELL";
      string pattern = GetEngulfName(g_h1EngulfType);
      BroadcastSignalToServer(action, g_symbol, entry, sl, tp1, tp2, pattern, lots);
   }
}

//+------------------------------------------------------------------+
//| Monitor Active Trades                                            |
//+------------------------------------------------------------------+
void MonitorTrades() {
   // Check batch 1 trades
   if(g_signalState == STATE_BATCH1_ACTIVE) {
      if(g_trade1_1.isOpen && g_trade1_1.ticket > 0) {
         if(!PositionSelectByTicket(g_trade1_1.ticket)) {
            g_trade1_1.isOpen = false;
            UpdateTradeStats(g_trade1_1.positionId, true);

            if(CheckIfTPHit(g_trade1_1.positionId)) {
               g_trade1_1.hitTP = true;
               g_stats.trade1_1_TPHits++;
               Log(g_symbol + " Trade 1 (1:1 RR) HIT TP", "TP_HIT");

               string direction = (g_trade1_1.tp > g_trade1_1.entryPrice) ? "BUY" : "SELL";
               BroadcastTPHit(g_symbol, direction, 1, g_trade1_1.entryPrice, g_trade1_1.tp, 0);

               if(AutoBreakeven && g_trade1_2.ticket > 0 && !g_trade1_2.breakevenSet) {
                  if(!PositionSelectByTicket(g_trade1_2.ticket)) {
                     g_trade1_2.breakevenSet = true;
                     g_trade1_2.isOpen = false;
                     Log("Trade 2 already closed - breakeven not needed", "BREAKEVEN");
                  } else {
                     Log("Trade 1 hit TP - Moving Trade 2 to breakeven...", "BREAKEVEN");
                     bool beResult = MoveToBreakeven(g_trade1_2.ticket, g_trade1_2.entryPrice);
                     g_trade1_2.breakevenSet = true;
                     if(beResult) {
                        BroadcastBreakeven(g_symbol, direction, g_trade1_2.entryPrice);
                     } else {
                        Log("Breakeven failed for Trade 2 - will not retry", "BREAKEVEN");
                     }
                  }
               }
            } else {
               Log(g_symbol + " Trade 1 (1:1 RR) closed (SL or manual)", "TRADE");
            }
         }
      }

      if(g_trade1_2.isOpen && g_trade1_2.ticket > 0) {
         if(!PositionSelectByTicket(g_trade1_2.ticket)) {
            g_trade1_2.isOpen = false;
            UpdateTradeStats(g_trade1_2.positionId, false);

            if(CheckIfTPHit(g_trade1_2.positionId)) {
               g_trade1_2.hitTP = true;
               g_stats.trade1_2_TPHits++;
               Log(g_symbol + " Trade 2 (1:2 RR) HIT TP", "TP_HIT");

               string direction = (g_trade1_2.tp > g_trade1_2.entryPrice) ? "BUY" : "SELL";
               BroadcastTPHit(g_symbol, direction, 2, g_trade1_2.entryPrice, g_trade1_2.tp, 0);
            } else {
               Log(g_symbol + " Trade 2 (1:2 RR) closed (SL or manual)", "TRADE");
            }
         }
      }

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
            UpdateTradeStats(g_trade2_1.positionId, true);

            if(CheckIfTPHit(g_trade2_1.positionId)) {
               g_trade2_1.hitTP = true;
               Log(g_symbol + " Batch 2 Trade 1 (1:1 RR) HIT TP", "TP_HIT");

               string direction = (g_trade2_1.tp > g_trade2_1.entryPrice) ? "BUY" : "SELL";
               BroadcastTPHit(g_symbol, direction, 1, g_trade2_1.entryPrice, g_trade2_1.tp, 0);

               if(AutoBreakeven && g_trade2_2.ticket > 0 && !g_trade2_2.breakevenSet) {
                  if(!PositionSelectByTicket(g_trade2_2.ticket)) {
                     g_trade2_2.breakevenSet = true;
                     g_trade2_2.isOpen = false;
                     Log("Batch 2 Trade 2 already closed - breakeven not needed", "BREAKEVEN");
                  } else {
                     Log("Batch 2 Trade 1 hit TP - Moving Trade 2 to breakeven...", "BREAKEVEN");
                     bool beResult = MoveToBreakeven(g_trade2_2.ticket, g_trade2_2.entryPrice);
                     g_trade2_2.breakevenSet = true;
                     if(beResult) {
                        BroadcastBreakeven(g_symbol, direction, g_trade2_2.entryPrice);
                     }
                  }
               }
            } else {
               Log(g_symbol + " Batch 2 Trade 1 closed (SL or manual)", "TRADE");
            }
         }
      }

      if(g_trade2_2.isOpen && g_trade2_2.ticket > 0) {
         if(!PositionSelectByTicket(g_trade2_2.ticket)) {
            g_trade2_2.isOpen = false;
            UpdateTradeStats(g_trade2_2.positionId, false);

            if(CheckIfTPHit(g_trade2_2.positionId)) {
               g_trade2_2.hitTP = true;
               Log(g_symbol + " Batch 2 Trade 2 (1:2 RR) HIT TP", "TP_HIT");

               string direction = (g_trade2_2.tp > g_trade2_2.entryPrice) ? "BUY" : "SELL";
               BroadcastTPHit(g_symbol, direction, 2, g_trade2_2.entryPrice, g_trade2_2.tp, 0);
            } else {
               Log(g_symbol + " Batch 2 Trade 2 closed (SL or manual)", "TRADE");
            }
         }
      }

      if(!g_trade2_1.isOpen && !g_trade2_2.isOpen) {
         g_signalState = STATE_SIGNAL_COMPLETE;
         Log(g_symbol + " Batch 2 complete - Signal finished", "STATE");
      }
   }

   if(g_signalState == STATE_SIGNAL_COMPLETE) {
      Log(g_symbol + " Resetting for new H1 signal", "RESET");
      ResetState();
   }
}

//+------------------------------------------------------------------+
//| Update Trade Stats from Closed Trade                             |
//+------------------------------------------------------------------+
void UpdateTradeStats(ulong positionId, bool isTrade1) {
   if(positionId == 0) return;

   if(!HistorySelectByPosition(positionId)) {
      HistorySelect(TimeCurrent() - 86400 * 7, TimeCurrent());
   }

   double profit = 0;
   double entryPrice = 0;
   double closePrice = 0;
   string action = "";
   int deals = HistoryDealsTotal();

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

   g_stats.totalTrades++;
   g_stats.netProfit += profit;

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

      g_stats.consecutiveWins++;
      g_stats.consecutiveLosses = 0;
      if(g_stats.consecutiveWins > g_stats.maxConsecutiveWins) {
         g_stats.maxConsecutiveWins = g_stats.consecutiveWins;
      }

      Log(g_symbol + " WIN: $" + DoubleToString(profit, 2) +
          " | Total P/L: $" + DoubleToString(g_stats.netProfit, 2), "STATS");
   } else if(profit < 0) {
      g_stats.losses++;
      g_stats.grossLoss += profit;
      if(profit < g_stats.largestLoss) {
         g_stats.largestLoss = profit;
      }

      g_stats.consecutiveLosses++;
      g_stats.consecutiveWins = 0;
      if(g_stats.consecutiveLosses > g_stats.maxConsecutiveLosses) {
         g_stats.maxConsecutiveLosses = g_stats.consecutiveLosses;
      }

      Log(g_symbol + " LOSS: $" + DoubleToString(profit, 2) +
          " | Total P/L: $" + DoubleToString(g_stats.netProfit, 2), "STATS");
   }

   if(action != "" && entryPrice > 0 && closePrice > 0) {
      string reason = (profit > 0) ? "TP_HIT" : "SL_HIT";
      BroadcastTradeClose(g_symbol, action, entryPrice, closePrice, profit, reason);
   }
}

//+------------------------------------------------------------------+
//| Check if Trade Hit TP                                            |
//+------------------------------------------------------------------+
bool CheckIfTPHit(ulong positionId) {
   if(positionId == 0) return false;

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

   if(!PositionSelectByTicket(ticket)) {
      Log("Position " + IntegerToString(ticket) + " no longer exists", "BE");
      return false;
   }

   double currentSL = PositionGetDouble(POSITION_SL);
   double currentTP = PositionGetDouble(POSITION_TP);
   string symbol = PositionGetString(POSITION_SYMBOL);
   ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   double pipSize = g_btcCalc.GetPipSize();

   double buffer = pipSize * BreakevenBufferPips;

   double newSL;
   if(posType == POSITION_TYPE_BUY) {
      newSL = NormalizeDouble(entryPrice + buffer, digits);
      if(newSL <= currentSL) {
         Log("Breakeven SL not better than current SL - skipping", "BE");
         return false;
      }
   } else {
      newSL = NormalizeDouble(entryPrice - buffer, digits);
      if(newSL >= currentSL) {
         Log("Breakeven SL not better than current SL - skipping", "BE");
         return false;
      }
   }

   double currentPrice = (posType == POSITION_TYPE_BUY) ?
      SymbolInfoDouble(symbol, SYMBOL_BID) : SymbolInfoDouble(symbol, SYMBOL_ASK);

   long freezeLevelPoints = SymbolInfoInteger(symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   double freezeLevel = freezeLevelPoints * point;

   if(freezeLevel > 0 && MathAbs(currentPrice - newSL) < freezeLevel) {
      Log(symbol + " Freeze level violation - cannot modify SL yet", "BE");
      return false;
   }

   long stopsLevelPoints = SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double stopsLevel = stopsLevelPoints * point;

   if(stopsLevel > 0 && MathAbs(currentPrice - newSL) < stopsLevel) {
      Log(symbol + " Stops level violation - adjusting SL", "BE");

      if(posType == POSITION_TYPE_BUY) {
         newSL = NormalizeDouble(currentPrice - stopsLevel - point, digits);
      } else {
         newSL = NormalizeDouble(currentPrice + stopsLevel + point, digits);
      }

      if((posType == POSITION_TYPE_BUY && newSL <= currentSL) ||
         (posType == POSITION_TYPE_SELL && newSL >= currentSL)) {
         Log(symbol + " Adjusted SL still not better than current SL - skipping", "BE");
         return false;
      }
   }

   int maxRetries = 3;
   for(int retry = 0; retry < maxRetries; retry++) {
      ResetLastError();
      if(trade.PositionModify(ticket, newSL, currentTP)) {
         Log(">>> BREAKEVEN SET <<< Ticket: " + IntegerToString(ticket) +
             " | Entry: " + DoubleToString(entryPrice, digits) +
             " | New SL: " + DoubleToString(newSL, digits), "BREAKEVEN");
         return true;
      }

      int error = GetLastError();
      Log(symbol + " Breakeven attempt " + IntegerToString(retry + 1) + "/" + IntegerToString(maxRetries) +
          " failed: Error " + IntegerToString(error), "ERROR");

      if(error == 10009 || error == 10013 || error == 10014 || error == 10015 ||
         error == 10016 || error == 10020 || error == 4756) {
         break;
      }

      Sleep(100);
   }

   return false;
}

//+------------------------------------------------------------------+
//| Process Symbol                                                   |
//+------------------------------------------------------------------+
void ProcessSymbol() {
   if(!g_symbolEnabled) return;

   SIGNAL_STATE state = g_signalState;

   static datetime lastStateLog = 0;
   if(TimeCurrent() - lastStateLog > 300) {
      lastStateLog = TimeCurrent();
      if(state != STATE_WAITING_H1_SIGNAL) {
         Log(g_symbol + " Current state: " + GetStateName(state) +
             " | Batch: " + IntegerToString(g_batchCount), "STATUS");
      }
   }

   MonitorTrades();

   state = g_signalState;

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
         break;

      case STATE_SIGNAL_COMPLETE:
         break;
   }
}

//+------------------------------------------------------------------+
//| Check if Signal Should Be Reset                                  |
//+------------------------------------------------------------------+
bool ShouldResetSignal() {
   SIGNAL_STATE state = g_signalState;

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

   if(state != STATE_WAITING_M5_RETEST &&
      state != STATE_WAITING_M5_ENGULFING &&
      state != STATE_WAITING_M5_RETEST2) {
      return false;
   }

   if(SignalTimeoutHours > 0 && g_h1SignalTime > 0) {
      datetime elapsed = TimeCurrent() - g_h1SignalTime;
      int hoursElapsed = (int)(elapsed / 3600);

      if(hoursElapsed >= SignalTimeoutHours) {
         Log(g_symbol + " Signal timeout: " + IntegerToString(hoursElapsed) + " hours elapsed", "TIMEOUT");
         return true;
      }
   }

   if(ResetOnNewH1Bar && g_h1SignalTime > 0) {
      int barsSinceSignal = iBarShift(g_symbol, HTF_TIMEFRAME, g_h1SignalTime);

      if(barsSinceSignal >= 2) {
         Log(g_symbol + " Signal stale: " + IntegerToString(barsSinceSignal) + " H1 bars since signal", "STALE");
         return true;
      }
   }

   if(ResetOnOppositeSignal && g_batchCount == 0) {
      static datetime lastCheckBar = 0;
      datetime currentH1Bar = iTime(g_symbol, HTF_TIMEFRAME, 0);

      if(currentH1Bar != lastCheckBar) {
         lastCheckBar = currentH1Bar;

         ENGULF_TYPE currentEngulf = DetectEngulfing(g_symbol, HTF_TIMEFRAME, 1);

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

   if(MaxTradesPerDay > 0) {
      if(g_dailyTrades >= MaxTradesPerDay) {
         return false;
      }
      if(g_dailyTrades >= MaxTradesPerDay - 2 && g_dailyTrades > 0) {
         static datetime lastLimitWarn = 0;
         if(TimeCurrent() - lastLimitWarn > 3600) {
            Log("Approaching daily trade limit: " + IntegerToString(g_dailyTrades) +
                "/" + IntegerToString(MaxTradesPerDay) + " trades", "LIMIT");
            lastLimitWarn = TimeCurrent();
         }
      }
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
   Log("BTC ENGULFING BOT v1.0 Starting", "INIT");
   Log("Based on GoldEngulfingBot v7 - Optimized for Bitcoin", "INIT");
   Log("Strategy: H1 Engulfing + EMA -> M5 Retest -> Dual Trade", "INIT");
   Log("Trades: 1:" + DoubleToString(RR_Trade1, 0) + " RR + 1:" + DoubleToString(RR_Trade2, 0) + " RR", "INIT");
   Log("Max Batches per H1 Signal: " + IntegerToString(MaxBatchesPerH1Signal), "INIT");

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(30);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   // Initialize BTC symbol
   if(!InitBTCSymbol()) {
      Alert("Failed to initialize BTC symbol!");
      return INIT_FAILED;
   }

   ZeroMemory(g_stats);
   g_stats.testStartTime = TimeCurrent();
   g_stats.initialBalance = account.Balance();
   g_stats.peakBalance = g_stats.initialBalance;

   g_dailyResetTime = TimeCurrent();
   g_dailyStartBalance = account.Balance();

   EventSetMillisecondTimer(TimerIntervalMs);

   Log("Symbol: " + g_symbol, "INIT");
   Log("Risk: " + (UsePercentageRisk ? DoubleToString(RiskPercent, 1) + "%" : "$" + DoubleToString(RiskDollars, 2)) + " per trade", "INIT");
   Log("ATR SL: Period=" + IntegerToString(ATR_Period) + " x " + DoubleToString(ATR_Multiplier, 1), "INIT");

   Log("--- SESSION SETTINGS ---", "INIT");
   if(EnableSessionFilter) {
      Log("Session Filter: ENABLED", "INIT");
   } else {
      Log("Session Filter: DISABLED (Trading 24/7 - Crypto Mode)", "INIT");
   }

   Log("Balance: $" + DoubleToString(account.Balance(), 2), "INIT");
   Log("========================================", "INIT");

   Comment("=== BTC ENGULFING BOT v1.0 ===\nInitializing...\nSymbol: " + g_symbol);

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Timer Function                                                   |
//+------------------------------------------------------------------+
void OnTimer() {
   if(!g_botEnabled) return;

   CheckDailyReset();

   static datetime lastFailsafeCheck = 0;
   if(TimeCurrent() - lastFailsafeCheck > 60) {
      lastFailsafeCheck = TimeCurrent();
      CheckStuckStates();
   }

   if(!CheckDailyLimits()) {
      UpdateChartComment("DAILY LIMIT REACHED");
      return;
   }

   // For BTC: No Asian session blocking (crypto trades 24/7)
   // Only block if session filter is explicitly enabled AND Asian trading disabled
   if(EnableSessionFilter && !TradeAsianSession && IsAsianSession()) {
      static datetime lastAsianLog = 0;
      if(TimeCurrent() - lastAsianLog > 3600) {
         Log("ASIAN SESSION BLOCKED (Filter enabled)", "SESSION");
         lastAsianLog = TimeCurrent();
      }
      UpdateChartComment("ASIAN SESSION - NO TRADING");
      return;
   }

   if(!IsTradingAllowedInSession()) {
      static datetime lastSessionLog = 0;
      if(TimeCurrent() - lastSessionLog > 3600) {
         string currentSession = GetCurrentSessionName();
         Log("Session Filter Active | Current: " + currentSession, "SESSION");
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
   status += "=== BTC ENGULFING BOT v1.0 ===\n";
   status += "Symbol: " + g_symbol + "\n";
   status += "State: " + GetStateName(g_signalState) + "\n";
   status += "Batch: " + IntegerToString(g_batchCount) + "/" + IntegerToString(MaxBatchesPerH1Signal) + "\n";
   status += "Signal Direction: " + (g_h1Direction == TREND_BULLISH ? "BULLISH" : (g_h1Direction == TREND_BEARISH ? "BEARISH" : "NONE")) + "\n";

   TREND_STATE h1EmaTrend = GetEMATrend(g_emaFastHandle[TF_H1], g_emaSlowHandle[TF_H1], 0);
   TREND_STATE m5EmaTrend = GetEMATrend(g_emaFastHandle[TF_M5], g_emaSlowHandle[TF_M5], 0);
   status += "H1 EMA Trend: " + GetTrendName(h1EmaTrend) + "\n";
   status += "M5 EMA Trend: " + GetTrendName(m5EmaTrend);

   if(g_h1Direction != TREND_NONE) {
      bool aligned = (m5EmaTrend == g_h1Direction);
      status += " (" + (aligned ? "ALIGNED" : "MISALIGNED") + ")";
   }
   status += "\n";

   if(g_h1SignalTime > 0) {
      int minsAgo = (int)((TimeCurrent() - g_h1SignalTime) / 60);
      status += "H1 Signal: " + IntegerToString(minsAgo) + " mins ago\n";
   }

   status += "Spread: " + DoubleToString(g_btcCalc.GetSpreadPips(), 1) + "/" + DoubleToString(MaxSpread_BTCUSD, 1) + " pips\n";
   status += "Daily Trades: " + IntegerToString(g_dailyTrades);
   if(MaxTradesPerDay > 0) {
      status += "/" + IntegerToString(MaxTradesPerDay);
   }
   status += "\n";
   status += "Daily P/L: $" + DoubleToString(g_dailyPnL, 2) + "\n";
   status += "Auto-Breakeven: " + (AutoBreakeven ? "ON" : "OFF") + "\n";

   int openPos = 0;
   if(g_trade1_1.isOpen) openPos++;
   if(g_trade1_2.isOpen) openPos++;
   if(g_trade2_1.isOpen) openPos++;
   if(g_trade2_2.isOpen) openPos++;
   status += "Open Positions: " + IntegerToString(openPos) + "\n";

   status += "\n--- ACTIVITY MONITOR ---\n";
   status += "H1 Bars Analyzed: " + IntegerToString(g_h1BarsAnalyzed) + "\n";
   status += "M5 Bars Analyzed: " + IntegerToString(g_m5BarsAnalyzed) + "\n";

   if(g_lastH1BarCheck > 0) {
      int secsAgoH1 = (int)(TimeCurrent() - g_lastH1BarCheck);
      int minsAgoH1 = secsAgoH1 / 60;
      status += "Last H1 Check: " + (minsAgoH1 > 0 ? IntegerToString(minsAgoH1) + "m " : "") +
                IntegerToString(secsAgoH1 % 60) + "s ago\n";
      status += "H1 Result: " + g_lastH1Result + "\n";
   } else {
      status += "Last H1 Check: Waiting for H1 bar...\n";
   }

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

   g_stats.testEndTime = TimeCurrent();

   PrintTradeStatistics();

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

   Comment("");
   RemoveVisualEMAs();
   Log("Bot stopped. Daily trades: " + IntegerToString(g_dailyTrades), "DEINIT");
}

//+------------------------------------------------------------------+
//| Print Trade Statistics                                           |
//+------------------------------------------------------------------+
void PrintTradeStatistics() {
   double finalBalance = AccountInfoDouble(ACCOUNT_BALANCE);

   Print("");
   Print("================================================================================");
   Print("                    BTC ENGULFING BOT v1.0 - TRADE REPORT                       ");
   Print("================================================================================");
   Print("");

   Print("TEST PERIOD");
   Print("  Start:           ", TimeToString(g_stats.testStartTime, TIME_DATE|TIME_MINUTES));
   Print("  End:             ", TimeToString(g_stats.testEndTime, TIME_DATE|TIME_MINUTES));
   Print("  Duration:        ", GetDurationString(g_stats.testEndTime - g_stats.testStartTime));
   Print("");

   Print("ACCOUNT SUMMARY");
   Print("  Initial Balance: $", DoubleToString(g_stats.initialBalance, 2));
   Print("  Final Balance:   $", DoubleToString(finalBalance, 2));
   Print("  Net Change:      $", DoubleToString(g_stats.netProfit, 2), " (", DoubleToString(g_stats.ReturnPercent(), 2), "%)");
   Print("");

   Print("--------------------------------------------------------------------------------");
   Print("                           PERFORMANCE SUMMARY                                  ");
   Print("--------------------------------------------------------------------------------");
   Print("  Total Net Profit:    $", DoubleToString(g_stats.netProfit, 2), " (", DoubleToString(g_stats.ReturnPercent(), 2), "%)");
   Print("  Gross Profit:        $", DoubleToString(g_stats.grossProfit, 2));
   Print("  Gross Loss:          $", DoubleToString(MathAbs(g_stats.grossLoss), 2));
   Print("  Profit Factor:       ", DoubleToString(g_stats.ProfitFactor(), 2));
   Print("  Max Drawdown:        $", DoubleToString(g_stats.maxDrawdown, 2), " (", DoubleToString(g_stats.DrawdownPercent(), 2), "%)");
   Print("");

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

   Print("  Max Consecutive Wins:   ", IntegerToString(g_stats.maxConsecutiveWins));
   Print("  Max Consecutive Losses: ", IntegerToString(g_stats.maxConsecutiveLosses));
   Print("");

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
