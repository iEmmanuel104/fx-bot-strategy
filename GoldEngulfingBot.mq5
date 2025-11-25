//+------------------------------------------------------------------+
//|                                           GoldEngulfingBot.mq5   |
//|                                  FXBot Gold Engulfing Strategy   |
//|                                           https://fxbot.trading  |
//+------------------------------------------------------------------+
#property copyright "FXBot Trading Platform"
#property link      "https://fxbot.trading"
#property version   "1.00"
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
input string   BotToken = "";                            // Bot Authentication Token
input int      MagicNumber = 10001;                      // Magic Number (Unique per user)

input group "=== Trading Configuration ==="
input double   RiskPercent = 1.0;                        // Risk per trade (%)
input double   MaxRiskPercent = 5.0;                     // Maximum risk allowed (%)
input int      WickClearance = 5;                        // Stop loss clearance in pips
input bool     EnableSecondTrade = true;                 // Enable second layer entry
input int      Slippage = 10;                            // Maximum slippage in points

input group "=== Connection Settings ==="
input int      HeartbeatInterval = 30;                   // Heartbeat interval (seconds)
input int      UpdateInterval = 5;                       // Position update interval (seconds)
input int      MaxRetries = 3;                           // Max retry attempts for requests

//+------------------------------------------------------------------+
//| Global Variables                                                 |
//+------------------------------------------------------------------+
CTrade trade;
CPositionInfo position;
CAccountInfo account;
CSymbolInfo symbolInfo;

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

// Bot state
EngulfingBar currentEngulfing;
bool firstTradeOpen = false;
bool secondTradeOpen = false;
int lastSignalBar = -1;
datetime lastHeartbeat = 0;
datetime lastUpdate = 0;
bool botEnabled = true;
string sessionId = "";
string jwtToken = "";  // Runtime JWT token from server

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

    // Authenticate with server
    if(!AuthenticateBot()) {
        Alert("Failed to authenticate with server!");
        return INIT_FAILED;
    }

    Print("Gold Engulfing Bot initialized successfully");
    Print("Symbol: ", _Symbol);
    Print("Server: ", ServerURL);
    Print("Magic Number: ", MagicNumber);
    Print("Risk: ", RiskPercent, "%");

    return INIT_SUCCEEDED;
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

    // Check for new bar
    static datetime lastBarTime = 0;
    datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);

    if(lastBarTime != currentBarTime) {
        lastBarTime = currentBarTime;
        OnNewBar();
    }

    // Monitor existing trades
    MonitorTrades();
}

//+------------------------------------------------------------------+
//| New bar event handler                                           |
//+------------------------------------------------------------------+
void OnNewBar() {
    // Check for engulfing pattern
    EngulfingBar bar;
    if(DetectEngulfingBar(bar) && !firstTradeOpen) {
        currentEngulfing = bar;
        ExecuteFirstTrade();
        lastSignalBar = iBars(_Symbol, PERIOD_CURRENT);
    }

    // Check for second trade condition
    if(firstTradeOpen && !secondTradeOpen && EnableSecondTrade) {
        CheckSecondTradeCondition();
    }
}

//+------------------------------------------------------------------+
//| Detect engulfing bar pattern                                    |
//+------------------------------------------------------------------+
bool DetectEngulfingBar(EngulfingBar &bar) {
    // Get previous and current bar data
    double prevOpen = iOpen(_Symbol, PERIOD_CURRENT, 2);
    double prevHigh = iHigh(_Symbol, PERIOD_CURRENT, 2);
    double prevLow = iLow(_Symbol, PERIOD_CURRENT, 2);
    double prevClose = iClose(_Symbol, PERIOD_CURRENT, 2);

    double currOpen = iOpen(_Symbol, PERIOD_CURRENT, 1);
    double currHigh = iHigh(_Symbol, PERIOD_CURRENT, 1);
    double currLow = iLow(_Symbol, PERIOD_CURRENT, 1);
    double currClose = iClose(_Symbol, PERIOD_CURRENT, 1);

    // Calculate body sizes
    double prevBody = MathAbs(prevClose - prevOpen);
    double currBody = MathAbs(currClose - currOpen);

    // Check for bullish engulfing
    bool bullishEngulfing = false;
    if(currClose > currOpen && prevClose < prevOpen) { // Current is bullish, previous is bearish
        if(currOpen <= prevClose && currClose >= prevOpen) { // Body engulfs
            bullishEngulfing = true;
        }
    }

    // Check for bearish engulfing
    bool bearishEngulfing = false;
    if(currClose < currOpen && prevClose > prevOpen) { // Current is bearish, previous is bullish
        if(currOpen >= prevClose && currClose <= prevOpen) { // Body engulfs
            bearishEngulfing = true;
        }
    }

    // Fill bar structure
    if(bullishEngulfing || bearishEngulfing) {
        bar.open = currOpen;
        bar.high = currHigh;
        bar.low = currLow;
        bar.close = currClose;
        bar.time = iTime(_Symbol, PERIOD_CURRENT, 1);
        bar.isBullish = bullishEngulfing;
        bar.isValid = true;

        // Send signal to server
        SendSignalNotification(bar);

        return true;
    }

    return false;
}

//+------------------------------------------------------------------+
//| Execute first trade based on engulfing pattern                  |
//+------------------------------------------------------------------+
void ExecuteFirstTrade() {
    if(!currentEngulfing.isValid) return;

    double lotSize = CalculateLotSize();
    double stopLoss, takeProfit, entryPrice;

    if(currentEngulfing.isBullish) {
        // Bullish trade
        entryPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        stopLoss = currentEngulfing.low - WickClearance * _Point * 10; // 5 pips below low
        takeProfit = 0; // No fixed TP, managed by next candle

        if(trade.Buy(lotSize, _Symbol, entryPrice, stopLoss, takeProfit, "Gold Engulfing Buy #1")) {
            firstTradeOpen = true;
            Print("First BUY trade opened at ", entryPrice, " SL: ", stopLoss);
            SendTradeNotification("BUY", lotSize, entryPrice, stopLoss);
        }
    } else {
        // Bearish trade
        entryPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        stopLoss = currentEngulfing.high + WickClearance * _Point * 10; // 5 pips above high
        takeProfit = 0; // No fixed TP, managed by next candle

        if(trade.Sell(lotSize, _Symbol, entryPrice, stopLoss, takeProfit, "Gold Engulfing Sell #1")) {
            firstTradeOpen = true;
            Print("First SELL trade opened at ", entryPrice, " SL: ", stopLoss);
            SendTradeNotification("SELL", lotSize, entryPrice, stopLoss);
        }
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
        // Check if last candle closed bullish
        sameDirection = (lastClose > lastOpen);
    } else {
        // Check if last candle closed bearish
        sameDirection = (lastClose < lastOpen);
    }

    // Close first trade
    CloseTradesByComment("Gold Engulfing Buy #1");
    CloseTradesByComment("Gold Engulfing Sell #1");
    firstTradeOpen = false;

    if(sameDirection && EnableSecondTrade) {
        // Open second trade
        ExecuteSecondTrade(lastLow, lastHigh);
    } else {
        // Reset for next signal
        ResetTradingState();
    }
}

//+------------------------------------------------------------------+
//| Execute second trade                                            |
//+------------------------------------------------------------------+
void ExecuteSecondTrade(double lastLow, double lastHigh) {
    double lotSize = CalculateLotSize();
    double stopLoss, takeProfit, entryPrice;

    if(currentEngulfing.isBullish) {
        // Bullish trade
        entryPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        stopLoss = lastLow - WickClearance * _Point * 10;
        takeProfit = 0;

        if(trade.Buy(lotSize, _Symbol, entryPrice, stopLoss, takeProfit, "Gold Engulfing Buy #2")) {
            secondTradeOpen = true;
            Print("Second BUY trade opened at ", entryPrice, " SL: ", stopLoss);
            SendTradeNotification("BUY", lotSize, entryPrice, stopLoss);
        }
    } else {
        // Bearish trade
        entryPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        stopLoss = lastHigh + WickClearance * _Point * 10;
        takeProfit = 0;

        if(trade.Sell(lotSize, _Symbol, entryPrice, stopLoss, takeProfit, "Gold Engulfing Sell #2")) {
            secondTradeOpen = true;
            Print("Second SELL trade opened at ", entryPrice, " SL: ", stopLoss);
            SendTradeNotification("SELL", lotSize, entryPrice, stopLoss);
        }
    }
}

//+------------------------------------------------------------------+
//| Monitor and manage open trades                                  |
//+------------------------------------------------------------------+
void MonitorTrades() {
    // Check if second trade needs to be closed
    if(secondTradeOpen) {
        static int secondTradeBar = 0;
        if(secondTradeBar == 0) {
            secondTradeBar = iBars(_Symbol, PERIOD_CURRENT);
        }

        // Close after one bar
        if(iBars(_Symbol, PERIOD_CURRENT) > secondTradeBar + 1) {
            CloseTradesByComment("Gold Engulfing Buy #2");
            CloseTradesByComment("Gold Engulfing Sell #2");
            secondTradeOpen = false;
            secondTradeBar = 0;
            ResetTradingState();
        }
    }
}

//+------------------------------------------------------------------+
//| Calculate lot size based on risk                                |
//+------------------------------------------------------------------+
double CalculateLotSize() {
    double balance = account.Balance();
    double riskAmount = balance * (RiskPercent / 100.0);

    // Calculate stop loss distance in pips
    double stopDistance = WickClearance + 10; // Average engulfing wick + clearance

    // Get pip value for 1 lot
    double pipValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    if(SymbolInfoInteger(_Symbol, SYMBOL_DIGITS) == 3 || SymbolInfoInteger(_Symbol, SYMBOL_DIGITS) == 5) {
        pipValue = pipValue * 10;
    }

    // Calculate lot size
    double lotSize = riskAmount / (stopDistance * pipValue);

    // Apply constraints
    double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

    lotSize = MathMax(minLot, lotSize);
    lotSize = MathMin(maxLot, lotSize);
    lotSize = MathRound(lotSize / lotStep) * lotStep;

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
}

//+------------------------------------------------------------------+
//| HTTP Request Helper                                             |
//+------------------------------------------------------------------+
bool SendHTTPRequest(string endpoint, string method, string &data, string &response) {
    string headers = "Content-Type: application/json\r\n";

    // Use runtime JWT token from authentication
    if(StringLen(jwtToken) > 0) {
        headers += "Authorization: Bearer " + jwtToken + "\r\n";
        Print("DEBUG: Sending JWT token (length: ", StringLen(jwtToken), ")");
    } else {
        Print("WARNING: No JWT token available!");
    }

    if(StringLen(sessionId) > 0) {
        headers += "X-Session-Id: " + sessionId + "\r\n";
    }

    char post[], result[];
    // Convert string to char array without null terminator to avoid JSON corruption
    int dataLen = StringLen(data);
    ArrayResize(post, dataLen);
    StringToCharArray(data, post, 0, dataLen);

    string url = ServerURL + endpoint;
    string responseHeaders = "";

    int res = WebRequest(method, url, headers, 5000, post, result, responseHeaders);

    if(res == 200 || res == 201) {
        // Convert result char array back to string (this is the actual JSON response body)
        response = CharArrayToString(result);
        return true;
    }

    Print("HTTP Request failed!");
    Print("  Endpoint: ", endpoint);
    Print("  Status Code: ", res);
    Print("  Request Data: ", data);
    Print("  Response Headers: ", responseHeaders);
    return false;
}

//+------------------------------------------------------------------+
//| Authenticate bot with server                                    |
//+------------------------------------------------------------------+
bool AuthenticateBot() {
    Print("=== Starting Authentication ===");
    Print("Account Login: ", account.Login());
    Print("Account Company: ", account.Company());
    Print("Symbol: ", _Symbol);
    Print("Magic Number: ", MagicNumber);

    string data = "{";
    data += "\"magicNumber\":" + IntegerToString(MagicNumber) + ",";
    data += "\"accountNumber\":\"" + IntegerToString(account.Login()) + "\",";
    data += "\"broker\":\"" + account.Company() + "\",";
    data += "\"symbol\":\"" + _Symbol + "\",";
    data += "\"version\":\"1.0.0\"";
    data += "}";

    Print("Auth Request JSON: ", data);

    string response;
    if(SendHTTPRequest("/mt5/auth", "POST", data, response)) {
        Print("Auth Response: ", response);

        // Parse session ID from response
        int start = StringFind(response, "\"sessionId\":\"");
        if(start >= 0) {
            start += 13;
            int end = StringFind(response, "\"", start);
            sessionId = StringSubstr(response, start, end - start);
            Print("Session ID: ", sessionId);
        } else {
            Print("ERROR: sessionId not found in response");
            return false;
        }

        // Parse JWT token from response
        start = StringFind(response, "\"jwtToken\":\"");
        if(start >= 0) {
            start += 12;
            int end = StringFind(response, "\"", start);
            jwtToken = StringSubstr(response, start, end - start);
            Print("JWT Token received (length: ", StringLen(jwtToken), ")");
            Print("Authenticated successfully!");
            return true;
        } else {
            Print("ERROR: jwtToken not found in response");
            return false;
        }
    } else {
        Print("ERROR: Authentication request failed");
    }

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
    data += "\"botEnabled\":" + (botEnabled ? "true" : "false");
    data += "}";

    string response;
    if(SendHTTPRequest("/mt5/heartbeat", "POST", data, response)) {
        // Check for commands from server
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
                positions += "\"openPrice\":" + DoubleToString(position.PriceOpen(), 5) + ",";
                positions += "\"currentPrice\":" + DoubleToString(position.PriceCurrent(), 5) + ",";
                positions += "\"stopLoss\":" + DoubleToString(position.StopLoss(), 5) + ",";
                positions += "\"takeProfit\":" + DoubleToString(position.TakeProfit(), 5) + ",";
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
    data += "\"open\":" + DoubleToString(bar.open, 5) + ",";
    data += "\"high\":" + DoubleToString(bar.high, 5) + ",";
    data += "\"low\":" + DoubleToString(bar.low, 5) + ",";
    data += "\"close\":" + DoubleToString(bar.close, 5) + ",";
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
    data += "\"price\":" + DoubleToString(price, 5) + ",";
    data += "\"stopLoss\":" + DoubleToString(sl, 5) + ",";
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
