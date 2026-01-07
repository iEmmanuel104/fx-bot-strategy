  ---
  Broadcast Mode (Multi-Account)

  | Setting         | Default   | Behavior                                                         |
  |-----------------|-----------|------------------------------------------------------------------|
  | BroadcastMode   | true      | Sends trade signals to external server for multi-account copying |
  | BroadcastURL    | (API URL) | Endpoint where signals are sent                                  |
  | BroadcastAPIKey | (API Key) | Authentication key for the broadcast server                      |
  | ExecuteOnMaster | true      | Also executes trades on this account (not just broadcasts)       |

  ---
  Server Configuration

  | Setting                | Default | Behavior                                |
  |------------------------|---------|-----------------------------------------|
  | MagicNumber            | 247891  | Unique ID to identify this bot's trades |
  | EnableServerConnection | true    | Connects to server for heartbeat/status |
  | HeartbeatIntervalSec   | 30      | Sends status ping every 30 seconds      |

  ---
  EMA Settings

  | Setting         | Default     | Behavior                        |
  |-----------------|-------------|---------------------------------|
  | EMA_Fast_Period | 10          | Fast EMA uses 10-period average |
  | EMA_Slow_Period | 23          | Slow EMA uses 23-period average |
  | EMA_Price       | PRICE_CLOSE | EMAs calculated on close prices |

  ---
  Timeframe Settings

  | Setting       | Default | Behavior                                    |
  |---------------|---------|---------------------------------------------|
  | HTF_Timeframe | H1      | Looks for engulfing signals on 1-hour chart |
  | LTF_Timeframe | M5      | Confirms entry on 5-minute chart            |

  ---
  Risk Management

  | Setting             | Default | Behavior                                              |
  |---------------------|---------|-------------------------------------------------------|
  | UsePercentageRisk   | true    | Risks percentage of balance (not fixed dollars)       |
  | RiskPercent         | 1.0     | Risks 1% of account per trade (2% total per batch)    |
  | RiskDollars         | $100    | Only used if UsePercentageRisk = false                |
  | MinRiskPercent      | 1.0     | Won't risk less than 1% even if calculated lower      |
  | MaxRiskPercent      | 5.0     | Won't risk more than 5% even if calculated higher     |
  | RR_Trade1           | 1.0     | First trade targets 1:1 risk-reward                   |
  | RR_Trade2           | 2.0     | Second trade targets 1:2 risk-reward                  |
  | AutoBreakeven       | true    | When Trade 1 hits TP, Trade 2's SL moves to breakeven |
  | BreakevenBufferPips | 5       | Breakeven SL is entry + 5 pips profit                 |

  ---
  ATR Stop Loss Settings

  | Setting          | Default | Behavior                                |
  |------------------|---------|-----------------------------------------|
  | ATR_Period       | 14      | Uses 14-period ATR for volatility       |
  | ATR_Multiplier   | 1.5     | SL = ATR × 1.5                          |
  | SpreadBufferPips | 3       | Adds 3 pips to SL for spread protection |
  | MinSLPips        | 10      | SL never smaller than 10 pips           |
  | MaxSLPips        | 100     | SL never larger than 100 pips           |

  ---
  Gold Settings

  | Setting          | Default | Behavior                             |
  |------------------|---------|--------------------------------------|
  | MaxSpread_XAUUSD | 15.0    | Won't trade Gold if spread > 15 pips |

  ---
  Trade Batch Settings

  | Setting               | Default | Behavior                                            |
  |-----------------------|---------|-----------------------------------------------------|
  | MaxBatchesPerH1Signal | 2       | Up to 2 batches (4 trades total) per H1 signal      |
  | SignalTimeoutHours    | 4       | Signal expires after 4 hours if no entry            |
  | ResetOnNewH1Bar       | true    | Resets if 2 H1 bars pass without trade              |
  | ResetOnOppositeSignal | true    | Cancels bullish signal if bearish engulfing appears |

  ---
  Position Limits

  | Setting               | Default | Behavior                                      |
  |-----------------------|---------|-----------------------------------------------|
  | MaxPositionsPerSymbol | 10      | Max 10 positions on Gold at once              |
  | MaxTotalPositions     | 20      | Max 20 total positions across all symbols     |
  | MarginBufferPercent   | 10.0    | Keeps 10% margin buffer (won't over-leverage) |

  ---
  Trading Sessions ⚠️ KEY SETTINGS

  | Setting             | Default | Behavior                                          |
  |---------------------|---------|---------------------------------------------------|
  | EnableSessionFilter | false   | DISABLED = trades 24/7 (ignores session settings) |
  | BrokerGMTOffset     | 2       | Your broker is GMT+2                              |
  | TradeAsianSession   | false   | Asian session BLOCKED (00:00-09:00 GMT)           |
  | TradeLondonSession  | true    | London session ALLOWED (07:00-16:00 GMT)          |
  | TradeNewYorkSession | true    | New York session ALLOWED (13:00-22:00 GMT)        |

  How Session Filter Works:

  - If EnableSessionFilter = false → Bot trades 24/7, ignores all session settings
  - If EnableSessionFilter = true → Bot only trades during enabled sessions:
    - Asian: OFF (won't trade 00:00-09:00 GMT)
    - London: ON (will trade 07:00-16:00 GMT)
    - NY: ON (will trade 13:00-22:00 GMT)

  ---
  Daily Limits

  | Setting             | Default | Behavior                                         |
  |---------------------|---------|--------------------------------------------------|
  | MaxTradesPerDay     | 0       | UNLIMITED trades per day (each batch = 2 trades) |
  | MaxDailyLossPercent | 10.0    | Stops trading if account loses 10% in one day    |
  | DailyProfitTarget   | 0       | DISABLED - no profit target (set > 0 to enable)  |

  ---
  Debug

  | Setting         | Default | Behavior                               |
  |-----------------|---------|----------------------------------------|
  | EnableLogs      | true    | Prints log messages to Experts tab     |
  | VerboseLogs     | false   | Extra detailed logging (for debugging) |
  | TimerIntervalMs | 500     | Bot checks market every 500ms          |

  ---
  Quick Reference: What's Active by Default

  | Feature            | Status                                            |
  |--------------------|---------------------------------------------------|
  | Trading            | 24/7 (session filter disabled)                    |
  | Risk               | 1% per trade (2% per batch)                       |
  | Breakeven          | ON (moves to entry + 5 pips when Trade 1 hits TP) |
  | Trade limit        | Unlimited                                         |
  | Daily loss limit   | 10%                                               |
  | Batches per signal | 2 (4 trades max per H1 signal)                   


  