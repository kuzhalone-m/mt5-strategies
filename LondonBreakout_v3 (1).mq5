//+------------------------------------------------------------------+
//|  LondonBreakout_v3.mq5                                           |
//|  London Breakout Strategy v3 — ADX + EMA21 Filter               |
//|  For: AUR Markets Demo / Prop Firm Accounts                      |
//|  Purpose: Visual testing + signal marking + report generation    |
//+------------------------------------------------------------------+
#property copyright   "Beew Quant"
#property version     "3.00"
#property description "London Breakout v3 — ADX + EMA21 + Asian Range"
#property strict

//--- Indicator buffers for sub-window display
#property indicator_chart_window

//=================================================================
// INPUT PARAMETERS — All configurable from EA settings panel
//=================================================================

//--- Session Times (UTC)
input group           "=== SESSION SETTINGS ==="
input int             AsianEndHour      = 7;    // Asian session ends (UTC hour)
input int             AsianEndMinute    = 0;    // Asian session ends (UTC minute)
input int             LondonEndHour     = 10;   // London window closes (UTC hour)
input int             LondonEndMinute   = 0;    // London window closes (UTC minute)
input int             DailyResetHour    = 22;   // Prop firm daily DD reset (UTC)

//--- Strategy Filters
input group           "=== STRATEGY FILTERS ==="
input double          MinAsianRangePips = 8.0;  // Minimum Asian range (price points)
input int             EMA_Period        = 21;   // EMA period for direction filter
input int             ADX_Period        = 14;   // ADX period for regime filter
input double          ADX_Threshold     = 25.0; // ADX must be above this to trade
input double          ATR_MinPoints     = 7.0;  // Minimum ATR14 to trade (dead market filter)
input int             ATR_Period        = 14;   // ATR period

//--- Signal Scoring
input group           "=== CONFIDENCE SCORING ==="
input double          BaseConfidence    = 0.65; // Base score: breakout + EMA + ADX confirmed
input double          VolumeBoost       = 0.10; // Added if breakout bar volume > 20-bar avg
input double          H1_EMA_Boost      = 0.05; // Added if H1 EMA21 agrees with direction
input double          StrongADXBoost    = 0.05; // Added if ADX > 30 (strong trend)
input double          MinConfidence     = 0.70; // Minimum score to take the trade

//--- Exit Rules
input group           "=== EXIT RULES ==="
input double          SL_ATR_Multi      = 2.0;  // Stop loss = entry - (this x ATR14)
input double          TP_ATR_Multi      = 3.0;  // Take profit = entry + (this x ATR14)
input double          MinSL_Points      = 8.0;  // Minimum SL distance in price points
input bool            CloseAtSessionEnd = true; // Close open trade at London session end
input bool            CloseOnFriday     = true; // Close all positions Friday 16:30 UTC

//--- Risk Settings
input group           "=== RISK MANAGEMENT ==="
input double          RiskPercent       = 0.50; // Risk % per trade (0.5 = 0.5%)
input double          MaxDailyDD        = 3.50; // Daily DD halt % (3.5 = 3.5%)
input int             MaxPositions      = 1;    // Max concurrent positions on XAUUSD
input double          LotJitter         = 0.10; // Lot size randomisation +/- 10%
input int             EntryDelayMS      = 1500; // Random delay before order (milliseconds)

//--- Visual Settings
input group           "=== VISUAL DISPLAY ==="
input bool            ShowAsianRange    = true; // Draw Asian session high/low lines
input bool            ShowSignals       = true; // Draw vertical lines at signal bars
input bool            ShowMissed        = true; // Draw vertical lines for missed signals
input bool            ShowSL_TP_Lines   = true; // Draw SL and TP horizontal lines on chart
input bool            ShowInfoPanel     = true; // Show live stats panel on chart
input color           BuySignalColor    = clrDodgerBlue;    // Vertical line: BUY signal taken
input color           SellSignalColor   = clrOrangeRed;     // Vertical line: SELL signal taken
input color           MissedSignalColor = clrGray;          // Vertical line: valid but missed
input color           FilteredColor     = clrDimGray;       // Vertical line: filtered out
input color           AsianHighColor    = clrDarkCyan;      // Asian session high line
input color           AsianLowColor     = clrDarkOrange;    // Asian session low line
input color           SL_Color          = clrRed;           // SL horizontal line
input color           TP_Color          = clrLimeGreen;     // TP horizontal line

//--- EA Mode
input group           "=== EA MODE ==="
input bool            LiveTrading       = false; // TRUE = place real orders. FALSE = signals only
input bool            LogAllBars        = false; // Log every bar check to Experts tab
input string          ReportComment     = "";    // Optional note added to report

//=================================================================
// GLOBAL VARIABLES
//=================================================================

// Indicator handles
int    h_EMA21, h_ADX, h_ATR;
int    h_EMA21_H1;

// Daily state
datetime lastTradeDate    = 0;
bool     tradedToday      = false;
double   dayStartEquity   = 0;
double   peakEquity       = 0;
bool     systemHalted     = false;

// Signal log for report
struct SignalRecord {
   datetime  time;
   string    direction;
   double    confidence;
   double    asian_high;
   double    asian_low;
   double    asian_range;
   double    adx_value;
   double    ema21_value;
   double    atr_value;
   double    entry_price;
   double    sl_price;
   double    tp_price;
   double    lot_size;
   string    outcome;      // "WIN" "LOSS" "SESSION_CLOSE" "PENDING" "FILTERED" "MISSED"
   string    filter_reason;
   double    pnl;
};

SignalRecord signals[];
int          signalCount = 0;

// Track current open trade
ulong  currentTicket  = 0;
double currentSL      = 0;
double currentTP      = 0;

//=================================================================
// INITIALISATION
//=================================================================

int OnInit()
{
   // Create indicator handles
   h_EMA21    = iMA(_Symbol, PERIOD_M15, EMA_Period, 0, MODE_EMA, PRICE_CLOSE);
   h_ADX      = iADX(_Symbol, PERIOD_M15, ADX_Period);
   h_ATR      = iATR(_Symbol, PERIOD_M15, ATR_Period);
   h_EMA21_H1 = iMA(_Symbol, PERIOD_H1, EMA_Period, 0, MODE_EMA, PRICE_CLOSE);

   if(h_EMA21 == INVALID_HANDLE || h_ADX == INVALID_HANDLE ||
      h_ATR == INVALID_HANDLE || h_EMA21_H1 == INVALID_HANDLE) {
      Alert("LB v3: Failed to create indicator handles. Check symbol and period.");
      return INIT_FAILED;
   }

   // Initialise equity tracking
   dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   peakEquity     = dayStartEquity;

   // Draw historical signals on chart
   if(ShowSignals) ScanAndMarkHistory();

   Print("London Breakout v3 initialised. Symbol: ", _Symbol,
         " | LiveTrading: ", LiveTrading,
         " | Min confidence: ", MinConfidence);

   if(!LiveTrading)
      Comment("LB v3 — SIGNAL MODE (no orders placed). Set LiveTrading=true to trade.");

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   IndicatorRelease(h_EMA21);
   IndicatorRelease(h_ADX);
   IndicatorRelease(h_ATR);
   IndicatorRelease(h_EMA21_H1);

   // Generate report on exit
   GenerateReport();

   ObjectsDeleteAll(0, "LB3_");
   Comment("");
}

//=================================================================
// MAIN TICK FUNCTION
//=================================================================

void OnTick()
{
   // Only process on new M15 bar
   static datetime lastBar = 0;
   datetime currentBar = iTime(_Symbol, PERIOD_M15, 0);
   if(currentBar == lastBar) return;
   lastBar = currentBar;

   // Update equity tracking
   UpdateEquityTracking();

   // System halt check
   if(systemHalted) {
      if(ShowInfoPanel) DrawInfoPanel("SYSTEM HALTED", clrRed);
      return;
   }

   // Friday close check
   if(CloseOnFriday && IsFridayClose()) {
      CloseAllPositions("Friday 16:30 UTC close");
      return;
   }

   // Daily reset check
   CheckDailyReset();

   // Session close check — close open trade at London end
   if(CloseAtSessionEnd && IsAfterLondon() && PositionExists()) {
      CloseAllPositions("London session end");
   }

   // Main logic — only during London window
   if(!InLondonWindow()) {
      if(ShowInfoPanel) DrawInfoPanel("", clrNONE);
      return;
   }

   // One trade per day
   if(tradedToday) {
      if(ShowInfoPanel) UpdateInfoPanel();
      return;
   }

   // Position already open
   if(PositionExists()) {
      if(ShowInfoPanel) UpdateInfoPanel();
      return;
   }

   // Run strategy check
   CheckSignal();

   if(ShowInfoPanel) UpdateInfoPanel();
}

//=================================================================
// CORE SIGNAL LOGIC
//=================================================================

void CheckSignal()
{
   // ----- STEP 1: Get Asian session range -----
   double asianHigh = 0, asianLow = 999999, asianRange = 0;
   if(!GetAsianRange(asianHigh, asianLow)) {
      if(LogAllBars) Print("LB3: Cannot calculate Asian range yet");
      return;
   }
   asianRange = asianHigh - asianLow;

   // Filter: minimum range
   if(asianRange < MinAsianRangePips) {
      DrawVertical(iTime(_Symbol, PERIOD_M15, 1),
                   "Range<Min " + DoubleToString(asianRange,1),
                   FilteredColor, STYLE_DOT, false);
      LogSignal(iTime(_Symbol, PERIOD_M15,1), "NONE", 0, asianHigh, asianLow,
                asianRange, 0, 0, 0, 0, 0, 0, 0, "FILTERED",
                "Asian range " + DoubleToString(asianRange,1) + " < " +
                DoubleToString(MinAsianRangePips,1));
      return;
   }

   // ----- STEP 2: Get indicator values -----
   double ema21_buf[3], adx_buf[3], atr_buf[3];
   if(CopyBuffer(h_EMA21, 0, 1, 3, ema21_buf) < 3) return;
   if(CopyBuffer(h_ADX,   0, 1, 3, adx_buf)   < 3) return;
   if(CopyBuffer(h_ATR,   0, 1, 3, atr_buf)   < 3) return;

   double ema21 = ema21_buf[2]; // [2] = 1 bar ago (confirmed closed bar)
   double adx   = adx_buf[2];
   double atr   = atr_buf[2];

   // Current bar (just closed = bar index 1)
   double barClose = iClose(_Symbol, PERIOD_M15, 1);
   double prevClose= iClose(_Symbol, PERIOD_M15, 2);
   double barTime  = iTime(_Symbol, PERIOD_M15, 1);

   // Filter: minimum ATR (dead market)
   if(atr < ATR_MinPoints) {
      if(LogAllBars)
         Print("LB3: ATR ", DoubleToString(atr,2), " < min ", ATR_MinPoints, " — skip");
      return;
   }

   // Filter: ADX regime check
   if(adx < ADX_Threshold) {
      DrawVertical((datetime)barTime,
                   "ADX=" + DoubleToString(adx,1) + "<" + DoubleToString(ADX_Threshold,0),
                   FilteredColor, STYLE_DOT, ShowMissed);
      LogSignal((datetime)barTime, "NONE", 0, asianHigh, asianLow, asianRange,
                adx, ema21, atr, 0, 0, 0, 0, "FILTERED",
                "ADX " + DoubleToString(adx,1) + " < " + DoubleToString(ADX_Threshold,0) + " (ranging)");
      return;
   }

   // ----- STEP 3: Breakout detection -----
   string direction = "";

   bool buyBreakout  = (barClose > asianHigh) && (prevClose <= asianHigh);
   bool sellBreakout = (barClose < asianLow)  && (prevClose >= asianLow);

   if(buyBreakout)       direction = "BUY";
   else if(sellBreakout) direction = "SELL";
   else {
      if(LogAllBars)
         Print("LB3: No breakout. Close=", barClose,
               " AsianH=", asianHigh, " AsianL=", asianLow);
      return;
   }

   // ----- STEP 4: EMA21 direction filter -----
   bool emaOK = (direction == "BUY"  && barClose > ema21) ||
                (direction == "SELL" && barClose < ema21);

   if(!emaOK) {
      DrawVertical((datetime)barTime,
                   direction + " EMA filtered (EMA=" + DoubleToString(ema21,2) + ")",
                   FilteredColor, STYLE_DASH, ShowMissed);
      LogSignal((datetime)barTime, direction, 0, asianHigh, asianLow, asianRange,
                adx, ema21, atr, barClose, 0, 0, 0, "FILTERED",
                "EMA21 filter — close " + DoubleToString(barClose,2) +
                (direction=="BUY" ? " not above " : " not below ") +
                "EMA21 " + DoubleToString(ema21,2));
      return;
   }

   // ----- STEP 5: Confidence scoring -----
   double confidence = BaseConfidence;
   string scoreBreakdown = "Base=" + DoubleToString(BaseConfidence,2);

   // Volume boost
   double barVolume = (double)iVolume(_Symbol, PERIOD_M15, 1);
   double avgVolume = GetAvgVolume(20);
   if(barVolume > avgVolume) {
      confidence += VolumeBoost;
      scoreBreakdown += " +Vol=" + DoubleToString(VolumeBoost,2);
   }

   // H1 EMA21 boost
   double h1ema_buf[2];
   if(CopyBuffer(h_EMA21_H1, 0, 1, 2, h1ema_buf) >= 2) {
      double h1ema  = h1ema_buf[1];
      double h1close= iClose(_Symbol, PERIOD_H1, 1);
      bool h1agrees = (direction=="BUY" && h1close > h1ema) ||
                      (direction=="SELL" && h1close < h1ema);
      if(h1agrees) {
         confidence += H1_EMA_Boost;
         scoreBreakdown += " +H1EMA=" + DoubleToString(H1_EMA_Boost,2);
      }
   }

   // Strong ADX boost
   if(adx > 30.0) {
      confidence += StrongADXBoost;
      scoreBreakdown += " +StrongADX=" + DoubleToString(StrongADXBoost,2);
   }

   // ----- STEP 6: Minimum confidence gate -----
   if(confidence < MinConfidence) {
      DrawVertical((datetime)barTime,
                   direction + " LowConf=" + DoubleToString(confidence,2),
                   MissedSignalColor, STYLE_DASH, ShowMissed);
      LogSignal((datetime)barTime, direction, confidence, asianHigh, asianLow,
                asianRange, adx, ema21, atr, barClose, 0, 0, 0, "FILTERED",
                "Confidence " + DoubleToString(confidence,2) + " < " +
                DoubleToString(MinConfidence,2));
      return;
   }

   // ----- STEP 7: Calculate SL and TP -----
   double entryPrice, sl, tp;

   if(direction == "BUY") {
      entryPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      sl = entryPrice - (SL_ATR_Multi * atr);
      tp = entryPrice + (TP_ATR_Multi * atr);
      // Minimum SL distance
      if((entryPrice - sl) < MinSL_Points) {
         sl = entryPrice - MinSL_Points;
         tp = entryPrice + (TP_ATR_Multi / SL_ATR_Multi * MinSL_Points);
      }
   } else {
      entryPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      sl = entryPrice + (SL_ATR_Multi * atr);
      tp = entryPrice - (TP_ATR_Multi * atr);
      if((sl - entryPrice) < MinSL_Points) {
         sl = entryPrice + MinSL_Points;
         tp = entryPrice - (TP_ATR_Multi / SL_ATR_Multi * MinSL_Points);
      }
   }

   double rrRatio = MathAbs(tp - entryPrice) / MathAbs(entryPrice - sl);

   // ----- STEP 8: Calculate lot size -----
   double lotSize = CalculateLotSize(entryPrice, sl);

   // ----- STEP 9: Draw Asian range lines -----
   if(ShowAsianRange) DrawAsianRange(asianHigh, asianLow, (datetime)barTime);

   // ----- STEP 10: Draw signal vertical line -----
   color sigColor = (direction == "BUY") ? BuySignalColor : SellSignalColor;
   string sigLabel = direction + " Conf=" + DoubleToString(confidence,2) +
                     " ADX=" + DoubleToString(adx,1) +
                     " RR=" + DoubleToString(rrRatio,1) + ":1";
   DrawVertical((datetime)barTime, sigLabel, sigColor, STYLE_SOLID, true);

   // Draw SL/TP lines
   if(ShowSL_TP_Lines) {
      DrawHorizontal("LB3_SL_" + TimeToString((datetime)barTime),
                     sl, SL_Color, "SL " + DoubleToString(sl, _Digits));
      DrawHorizontal("LB3_TP_" + TimeToString((datetime)barTime),
                     tp, TP_Color, "TP " + DoubleToString(tp, _Digits));
   }

   // ----- STEP 11: Log signal -----
   LogSignal((datetime)barTime, direction, confidence, asianHigh, asianLow,
             asianRange, adx, ema21, atr, entryPrice, sl, tp, lotSize, "PENDING", "");

   // Print to Experts log
   Print("=== LB3 SIGNAL =========================");
   Print("Direction:   ", direction);
   Print("Time:        ", TimeToString((datetime)barTime));
   Print("Entry:       ", entryPrice);
   Print("SL:          ", sl, " (", DoubleToString(MathAbs(entryPrice-sl),2), " pts)");
   Print("TP:          ", tp, " (", DoubleToString(MathAbs(tp-entryPrice),2), " pts)");
   Print("RR:          ", DoubleToString(rrRatio,2), ":1");
   Print("Confidence:  ", DoubleToString(confidence,2), " [", scoreBreakdown, "]");
   Print("ADX:         ", DoubleToString(adx,1));
   Print("EMA21:       ", DoubleToString(ema21,2));
   Print("ATR14:       ", DoubleToString(atr,2));
   Print("Asian High:  ", asianHigh, "  Low: ", asianLow, "  Range: ", asianRange);
   Print("Lot size:    ", DoubleToString(lotSize,2));
   Print("========================================");

   // ----- STEP 12: Place order if LiveTrading -----
   if(LiveTrading) {
      PlaceOrder(direction, entryPrice, sl, tp, lotSize, confidence);
   } else {
      Print("LB3: Signal logged — LiveTrading=false, no order placed.");
   }

   tradedToday = true;
}

//=================================================================
// ASIAN RANGE CALCULATION
//=================================================================

bool GetAsianRange(double &high, double &low)
{
   high = 0;
   low  = 999999;

   datetime now = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(now, dt);

   // Build today's Asian session boundaries
   datetime asianStart = StringToTime(
      StringFormat("%04d.%02d.%02d 00:00", dt.year, dt.mon, dt.day));
   datetime asianEnd = StringToTime(
      StringFormat("%04d.%02d.%02d %02d:%02d", dt.year, dt.mon, dt.day,
                   AsianEndHour, AsianEndMinute));

   int bars = iBars(_Symbol, PERIOD_M15);
   for(int i = 1; i < bars; i++) {
      datetime t = iTime(_Symbol, PERIOD_M15, i);
      if(t < asianStart) break;
      if(t >= asianEnd)  continue;

      double h = iHigh(_Symbol, PERIOD_M15, i);
      double l = iLow(_Symbol, PERIOD_M15, i);
      if(h > high) high = h;
      if(l < low)  low  = l;
   }

   return (high > 0 && low < 999999);
}

//=================================================================
// SESSION CHECKS
//=================================================================

bool InLondonWindow()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int currentMinutes = dt.hour * 60 + dt.min;
   int startMinutes   = AsianEndHour * 60 + AsianEndMinute;
   int endMinutes     = LondonEndHour * 60 + LondonEndMinute;
   return (currentMinutes >= startMinutes && currentMinutes < endMinutes);
}

bool IsAfterLondon()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int currentMinutes = dt.hour * 60 + dt.min;
   int endMinutes     = LondonEndHour * 60 + LondonEndMinute;
   return (currentMinutes >= endMinutes);
}

bool IsFridayClose()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   return (dt.day_of_week == 5 && dt.hour >= 16 && dt.min >= 30);
}

//=================================================================
// EQUITY TRACKING & RISK
//=================================================================

void UpdateEquityTracking()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);

   if(equity > peakEquity) peakEquity = equity;

   if(dayStartEquity > 0) {
      double dailyDD = (dayStartEquity - equity) / dayStartEquity * 100.0;
      if(dailyDD >= MaxDailyDD) {
         Print("LB3: DAILY DD HALT — DD=", DoubleToString(dailyDD,2),
               "% >= ", MaxDailyDD, "%");
         CloseAllPositions("Daily DD halt " + DoubleToString(dailyDD,2) + "%");
         systemHalted = true;
      }
   }
}

void CheckDailyReset()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.hour == DailyResetHour && dt.min == 0) {
      MqlDateTime lastTrade;
      TimeToStruct(lastTradeDate, lastTrade);
      if(lastTrade.day != dt.day) {
         tradedToday    = false;
         dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
         systemHalted   = false;
         Print("LB3: Daily reset. Day start equity: ", dayStartEquity);
      }
   }
   // Also reset traded flag at midnight
   MqlDateTime last;
   TimeToStruct(lastTradeDate, last);
   if(last.day != dt.day && dt.hour == 0) tradedToday = false;
}

//=================================================================
// ORDER PLACEMENT
//=================================================================

double CalculateLotSize(double entry, double sl)
{
   double equity      = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskAmount  = equity * (RiskPercent / 100.0);
   double slDistance  = MathAbs(entry - sl);
   double tickSize    = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);

   if(slDistance == 0 || tickSize == 0) return 0.01;

   double lot = riskAmount / (slDistance / tickSize * tickValue);

   // Apply jitter
   double jitter = 1.0 + ((MathRand() / 32767.0 * 2.0 - 1.0) * LotJitter);
   lot *= jitter;

   // Clamp to broker limits
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lot = MathMax(lot, minLot);
   lot = MathMin(lot, maxLot);
   lot = MathRound(lot / lotStep) * lotStep;

   return NormalizeDouble(lot, 2);
}

bool PlaceOrder(string direction, double entry, double sl, double tp,
                double lot, double confidence)
{
   // Anti-detection delay
   int delay = EntryDelayMS + (int)(MathRand() / 32767.0 * 1000);
   Sleep(delay);

   MqlTradeRequest  req  = {};
   MqlTradeResult   res  = {};

   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = _Symbol;
   req.volume       = lot;
   req.type         = (direction == "BUY") ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   req.price        = (direction == "BUY") ?
                      SymbolInfoDouble(_Symbol, SYMBOL_ASK) :
                      SymbolInfoDouble(_Symbol, SYMBOL_BID);
   req.sl           = sl;
   req.tp           = tp;
   req.deviation    = 20;
   req.magic        = 20260101;
   req.comment      = StringFormat("LBv3_C%.2f_ADX%.0f", confidence,
                                   GetIndicatorValue(h_ADX, 1));
   req.type_filling = ORDER_FILLING_IOC;

   bool ok = OrderSend(req, res);

   if(ok && res.retcode == TRADE_RETCODE_DONE) {
      currentTicket = res.order;
      currentSL     = sl;
      currentTP     = tp;
      lastTradeDate = TimeCurrent();
      Print("LB3: Order placed. Ticket=", res.order,
            " Fill=", res.price, " Lot=", lot);
      // Update signal log outcome
      UpdateSignalOutcome(signalCount - 1, "PENDING", 0);
      return true;
   } else {
      Print("LB3: Order failed. Retcode=", res.retcode,
            " Comment=", res.comment);
      UpdateSignalOutcome(signalCount - 1, "ORDER_FAILED", 0);
      return false;
   }
}

void CloseAllPositions(string reason)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != 20260101) continue;

      MqlTradeRequest req = {};
      MqlTradeResult  res = {};
      req.action   = TRADE_ACTION_DEAL;
      req.position = ticket;
      req.symbol   = _Symbol;
      req.volume   = PositionGetDouble(POSITION_VOLUME);
      req.type     = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ?
                     ORDER_TYPE_SELL : ORDER_TYPE_BUY;
      req.price    = (req.type == ORDER_TYPE_SELL) ?
                     SymbolInfoDouble(_Symbol, SYMBOL_BID) :
                     SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      req.deviation = 20;
      req.magic    = 20260101;
      req.comment  = "LBv3_close:" + reason;
      req.type_filling = ORDER_FILLING_IOC;

      double pnl = PositionGetDouble(POSITION_PROFIT);
      OrderSend(req, res);
      Print("LB3: Closed ticket ", ticket, " Reason: ", reason, " PnL: ", pnl);
   }
}

bool PositionExists()
{
   for(int i = 0; i < PositionsTotal(); i++) {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == 20260101) return true;
   }
   return false;
}

//=================================================================
// VISUAL DRAWING FUNCTIONS
//=================================================================

void DrawVertical(datetime t, string label, color clr, ENUM_LINE_STYLE style,
                  bool visible)
{
   if(!visible) return;
   string name = "LB3_VL_" + TimeToString(t) + "_" + label;
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_VLINE, 0, t, 0);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_STYLE, style);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, (style == STYLE_SOLID) ? 2 : 1);
   ObjectSetString(0, name, OBJPROP_TOOLTIP, label);
   ObjectSetString(0, name, OBJPROP_TEXT, label);
}

void DrawHorizontal(string name, double price, color clr, string label)
{
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_HLINE, 0, 0, price);
   ObjectSetDouble(0, name, OBJPROP_PRICE, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DASH);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
   ObjectSetString(0, name, OBJPROP_TEXT, label);
   ObjectSetString(0, name, OBJPROP_TOOLTIP, label);
}

void DrawAsianRange(double high, double low, datetime signalTime)
{
   string nameH = "LB3_AsianH_" + TimeToString(signalTime);
   string nameL = "LB3_AsianL_" + TimeToString(signalTime);

   if(ObjectFind(0, nameH) < 0)
      ObjectCreate(0, nameH, OBJ_HLINE, 0, 0, high);
   ObjectSetDouble(0, nameH,  OBJPROP_PRICE, high);
   ObjectSetInteger(0, nameH, OBJPROP_COLOR, AsianHighColor);
   ObjectSetInteger(0, nameH, OBJPROP_STYLE, STYLE_DOT);
   ObjectSetString(0, nameH,  OBJPROP_TEXT, "Asian High: " + DoubleToString(high,2));

   if(ObjectFind(0, nameL) < 0)
      ObjectCreate(0, nameL, OBJ_HLINE, 0, 0, low);
   ObjectSetDouble(0, nameL,  OBJPROP_PRICE, low);
   ObjectSetInteger(0, nameL, OBJPROP_COLOR, AsianLowColor);
   ObjectSetInteger(0, nameL, OBJPROP_STYLE, STYLE_DOT);
   ObjectSetString(0, nameL,  OBJPROP_TEXT, "Asian Low: " + DoubleToString(low,2));
}

void DrawInfoPanel(string overrideMsg, color overrideClr)
{
   string name = "LB3_Panel";
   string msg;

   if(overrideMsg != "") {
      msg = "LB v3 | " + overrideMsg;
   } else {
      double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
      double dailyDD = (dayStartEquity > 0) ?
                       (dayStartEquity - equity) / dayStartEquity * 100.0 : 0;
      msg = StringFormat(
         "LB v3 | Equity: %.2f | Daily DD: %.2f%% / %.1f%% | "
         "Traded: %s | Halted: %s | Mode: %s",
         equity, dailyDD, MaxDailyDD,
         tradedToday ? "YES" : "NO",
         systemHalted ? "YES" : "NO",
         LiveTrading ? "LIVE" : "SIGNAL ONLY");
   }
   Comment(msg);
}

void UpdateInfoPanel() { DrawInfoPanel("", clrNONE); }

//=================================================================
// HISTORY SCAN — Draw markers on historical bars
//=================================================================

void ScanAndMarkHistory()
{
   Print("LB3: Scanning history for signals...");
   int totalBars = iBars(_Symbol, PERIOD_M15);
   int marked    = 0;

   // Only scan last 500 bars (about 5 days of M15)
   int scanBars = MathMin(totalBars - 3, 500);

   for(int i = scanBars; i >= 2; i--) {
      datetime t = iTime(_Symbol, PERIOD_M15, i);
      MqlDateTime dt;
      TimeToStruct(t, dt);

      // Only London window
      int mins = dt.hour * 60 + dt.min;
      int startMins = AsianEndHour * 60 + AsianEndMinute;
      int endMins   = LondonEndHour * 60 + LondonEndMinute;
      if(mins < startMins || mins >= endMins) continue;

      // Get Asian range for this bar's day
      double ah = 0, al = 999999;
      bool rangeOK = GetAsianRangeForDate(dt.year, dt.mon, dt.day, ah, al);
      if(!rangeOK) continue;
      double ar = ah - al;
      if(ar < MinAsianRangePips) continue;

      // Get indicator values
      double ema21_b[1], adx_b[1], atr_b[1];
      if(CopyBuffer(h_EMA21, 0, i, 1, ema21_b) < 1) continue;
      if(CopyBuffer(h_ADX,   0, i, 1, adx_b)   < 1) continue;
      if(CopyBuffer(h_ATR,   0, i, 1, atr_b)   < 1) continue;

      double ema21 = ema21_b[0];
      double adx   = adx_b[0];
      double atr   = atr_b[0];

      double barClose  = iClose(_Symbol, PERIOD_M15, i);
      double prevClose = iClose(_Symbol, PERIOD_M15, i + 1);

      bool buyB  = (barClose > ah) && (prevClose <= ah);
      bool sellB = (barClose < al) && (prevClose >= al);
      if(!buyB && !sellB) continue;

      string dir = buyB ? "BUY" : "SELL";

      // ADX filter
      if(adx < ADX_Threshold) {
         DrawVertical(t, dir + " ADX=" + DoubleToString(adx,1) + " FILTERED",
                      FilteredColor, STYLE_DOT, ShowMissed);
         marked++;
         continue;
      }

      // EMA filter
      bool emaOK = (dir=="BUY" && barClose > ema21) ||
                   (dir=="SELL" && barClose < ema21);
      if(!emaOK) {
         DrawVertical(t, dir + " EMA_FILTERED",
                      FilteredColor, STYLE_DASH, ShowMissed);
         marked++;
         continue;
      }

      // Confidence
      double conf = BaseConfidence;
      double vol  = (double)iVolume(_Symbol, PERIOD_M15, i);
      double avgV = GetAvgVolumeAt(i, 20);
      if(vol > avgV) conf += VolumeBoost;
      if(adx > 30)   conf += StrongADXBoost;

      color sigClr = (conf >= MinConfidence) ?
                     ((dir=="BUY") ? BuySignalColor : SellSignalColor) :
                     MissedSignalColor;
      string tag = dir + " C=" + DoubleToString(conf,2) +
                   " ADX=" + DoubleToString(adx,1);
      DrawVertical(t, tag, sigClr, STYLE_SOLID, true);

      // Draw Asian range for this signal
      if(ShowAsianRange) DrawAsianRange(ah, al, t);
      marked++;
   }
   Print("LB3: History scan complete. Marked ", marked, " signal bars.");
}

bool GetAsianRangeForDate(int year, int mon, int day,
                          double &high, double &low)
{
   high = 0; low = 999999;
   datetime dayStart = StringToTime(StringFormat("%04d.%02d.%02d 00:00",
                                                  year, mon, day));
   datetime asianEnd = StringToTime(StringFormat("%04d.%02d.%02d %02d:%02d",
                                                  year, mon, day,
                                                  AsianEndHour, AsianEndMinute));
   int bars = iBars(_Symbol, PERIOD_M15);
   for(int i = 0; i < bars; i++) {
      datetime t = iTime(_Symbol, PERIOD_M15, i);
      if(t < dayStart) break;
      if(t >= asianEnd) continue;
      double h = iHigh(_Symbol, PERIOD_M15, i);
      double l = iLow(_Symbol, PERIOD_M15, i);
      if(h > high) high = h;
      if(l < low)  low  = l;
   }
   return (high > 0 && low < 999999);
}

//=================================================================
// HELPER FUNCTIONS
//=================================================================

double GetAvgVolume(int period)
{
   double total = 0;
   for(int i = 2; i <= period + 1; i++)
      total += (double)iVolume(_Symbol, PERIOD_M15, i);
   return total / period;
}

double GetAvgVolumeAt(int startBar, int period)
{
   double total = 0;
   for(int i = startBar + 1; i <= startBar + period; i++)
      total += (double)iVolume(_Symbol, PERIOD_M15, i);
   return total / period;
}

double GetIndicatorValue(int handle, int shift)
{
   double buf[1];
   if(CopyBuffer(handle, 0, shift, 1, buf) < 1) return 0;
   return buf[0];
}

//=================================================================
// SIGNAL LOGGING
//=================================================================

void LogSignal(datetime t, string dir, double conf,
               double ah, double al, double ar,
               double adx, double ema21, double atr,
               double entry, double sl, double tp, double lot,
               string outcome, string reason)
{
   ArrayResize(signals, signalCount + 1);
   signals[signalCount].time         = t;
   signals[signalCount].direction    = dir;
   signals[signalCount].confidence   = conf;
   signals[signalCount].asian_high   = ah;
   signals[signalCount].asian_low    = al;
   signals[signalCount].asian_range  = ar;
   signals[signalCount].adx_value    = adx;
   signals[signalCount].ema21_value  = ema21;
   signals[signalCount].atr_value    = atr;
   signals[signalCount].entry_price  = entry;
   signals[signalCount].sl_price     = sl;
   signals[signalCount].tp_price     = tp;
   signals[signalCount].lot_size     = lot;
   signals[signalCount].outcome      = outcome;
   signals[signalCount].filter_reason= reason;
   signals[signalCount].pnl          = 0;
   signalCount++;
}

void UpdateSignalOutcome(int idx, string outcome, double pnl)
{
   if(idx >= 0 && idx < signalCount) {
      signals[idx].outcome = outcome;
      signals[idx].pnl     = pnl;
   }
}

//=================================================================
// REPORT GENERATION
//=================================================================

void GenerateReport()
{
   if(signalCount == 0) {
      Print("LB3: No signals to report.");
      return;
   }

   string filename = "LB3_Report_" + TimeToString(TimeCurrent(), TIME_DATE) + ".csv";
   int fh = FileOpen(filename, FILE_WRITE | FILE_CSV | FILE_ANSI, ',');
   if(fh == INVALID_HANDLE) {
      Print("LB3: Cannot write report file.");
      return;
   }

   // Header row
   FileWrite(fh,
      "DateTime", "Day", "Direction", "Confidence",
      "Asian_High", "Asian_Low", "Asian_Range",
      "ADX", "EMA21", "ATR14",
      "Entry", "SL", "TP",
      "SL_Distance", "TP_Distance", "RR_Ratio",
      "Lot_Size", "Outcome", "Filter_Reason", "PnL_USD");

   // Data rows
   int wins=0, losses=0, filtered=0, missed=0, pending=0;
   double totalPnL = 0;

   for(int i = 0; i < signalCount; i++) {
      SignalRecord s = signals[i];
      MqlDateTime dt;
      TimeToStruct(s.time, dt);
      string dayName = GetDayName(dt.day_of_week);

      double slDist = (s.entry_price > 0 && s.sl_price > 0) ?
                      MathAbs(s.entry_price - s.sl_price) : 0;
      double tpDist = (s.entry_price > 0 && s.tp_price > 0) ?
                      MathAbs(s.tp_price - s.entry_price) : 0;
      double rr     = (slDist > 0) ? tpDist / slDist : 0;

      FileWrite(fh,
         TimeToString(s.time), dayName, s.direction,
         DoubleToString(s.confidence, 2),
         DoubleToString(s.asian_high, 2),
         DoubleToString(s.asian_low, 2),
         DoubleToString(s.asian_range, 2),
         DoubleToString(s.adx_value, 1),
         DoubleToString(s.ema21_value, 2),
         DoubleToString(s.atr_value, 2),
         DoubleToString(s.entry_price, 2),
         DoubleToString(s.sl_price, 2),
         DoubleToString(s.tp_price, 2),
         DoubleToString(slDist, 2),
         DoubleToString(tpDist, 2),
         DoubleToString(rr, 2),
         DoubleToString(s.lot_size, 2),
         s.outcome, s.filter_reason,
         DoubleToString(s.pnl, 2));

      if(s.outcome == "WIN")      { wins++;    totalPnL += s.pnl; }
      if(s.outcome == "LOSS")     { losses++;  totalPnL += s.pnl; }
      if(s.outcome == "FILTERED") filtered++;
      if(s.outcome == "MISSED")   missed++;
      if(s.outcome == "PENDING")  pending++;
   }

   // Summary block
   FileWrite(fh, "");
   FileWrite(fh, "=== SUMMARY ===");
   FileWrite(fh, "Total signals evaluated", signalCount);
   FileWrite(fh, "Trades taken (WIN+LOSS+PENDING)", wins+losses+pending);
   FileWrite(fh, "Wins", wins);
   FileWrite(fh, "Losses", losses);
   FileWrite(fh, "Win Rate %",
      DoubleToString((wins+losses>0) ? (double)wins/(wins+losses)*100 : 0, 1));
   FileWrite(fh, "Filtered (rule blocked)", filtered);
   FileWrite(fh, "Missed (confidence low)", missed);
   FileWrite(fh, "Total PnL USD", DoubleToString(totalPnL, 2));
   FileWrite(fh, "ADX Filter Threshold", ADX_Threshold);
   FileWrite(fh, "EMA Period", EMA_Period);
   FileWrite(fh, "SL ATR Multiplier", SL_ATR_Multi);
   FileWrite(fh, "TP ATR Multiplier", TP_ATR_Multi);
   FileWrite(fh, "Min Confidence", MinConfidence);
   FileWrite(fh, "Risk Per Trade %", RiskPercent);
   FileWrite(fh, "Session UTC", StringFormat("%02d:%02d - %02d:%02d",
             AsianEndHour, AsianEndMinute, LondonEndHour, LondonEndMinute));
   if(ReportComment != "")
      FileWrite(fh, "Notes", ReportComment);

   FileClose(fh);
   Print("LB3: Report saved → ", filename,
         " (", wins+losses+pending, " trades | ",
         wins, "W / ", losses, "L | PnL: $", DoubleToString(totalPnL,2), ")");
}

string GetDayName(int dow)
{
   string days[] = {"Sunday","Monday","Tuesday","Wednesday",
                    "Thursday","Friday","Saturday"};
   if(dow >= 0 && dow <= 6) return days[dow];
   return "Unknown";
}

//+------------------------------------------------------------------+
