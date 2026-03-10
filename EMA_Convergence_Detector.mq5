//+------------------------------------------------------------------+
//|                                    EMA_Convergence_Detector.mq5  |
//|                     EMA Convergence Detector – Invest Mode       |
//|                                                                  |
//|  BUY-only EA for invest (non-CFD) accounts.                      |
//|  Detects accelerating EMA convergence to open long positions.    |
//|  Uses the mirror logic (fast diverging above slow) to close.     |
//|  1% static stop-loss removed after EMA cross confirmed by 3 bars.|
//+------------------------------------------------------------------+
#property copyright "EMA Convergence Detector"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//--- Threshold mode
enum ENUM_THRESHOLD_MODE
{
   THRESHOLD_UNIFIED  = 0, // Unified (same for entry & exit)
   THRESHOLD_SEPARATE = 1  // Separate entry & exit
};

//--- Hour enums (H00-H23)
enum ENUM_TRADE_HOUR
{
   H00 = 0,  // 00:xx
   H01 = 1,  // 01:xx
   H02 = 2,  // 02:xx
   H03 = 3,  // 03:xx
   H04 = 4,  // 04:xx
   H05 = 5,  // 05:xx
   H06 = 6,  // 06:xx
   H07 = 7,  // 07:xx
   H08 = 8,  // 08:xx
   H09 = 9,  // 09:xx
   H10 = 10, // 10:xx
   H11 = 11, // 11:xx
   H12 = 12, // 12:xx
   H13 = 13, // 13:xx
   H14 = 14, // 14:xx
   H15 = 15, // 15:xx
   H16 = 16, // 16:xx
   H17 = 17, // 17:xx
   H18 = 18, // 18:xx
   H19 = 19, // 19:xx
   H20 = 20, // 20:xx
   H21 = 21, // 21:xx
   H22 = 22, // 22:xx
   H23 = 23  // 23:xx
};

//--- Minute enums (M00-M55, step 5)
enum ENUM_TRADE_MINUTE
{
   M00 = 0,  // xx:00
   M05 = 5,  // xx:05
   M10 = 10, // xx:10
   M15 = 15, // xx:15
   M20 = 20, // xx:20
   M25 = 25, // xx:25
   M30 = 30, // xx:30
   M35 = 35, // xx:35
   M40 = 40, // xx:40
   M45 = 45, // xx:45
   M50 = 50, // xx:50
   M55 = 55  // xx:55
};

//--- Input parameters
input int       InpFastPeriod      = 12;           // Fast EMA period
input int       InpSlowPeriod      = 26;           // Slow EMA period

//--- Threshold parameters
input ENUM_THRESHOLD_MODE InpThresholdMode = THRESHOLD_UNIFIED; // Threshold mode
input double    InpThreshold       = 0.05;          // Unified threshold (entry & exit)
input double    InpBuyThreshold    = 0.05;          // Entry threshold (Separate mode)
input double    InpCloseThreshold  = 0.05;          // Exit threshold (Separate mode)

input double    InpRiskPct         = 2.0;           // Risk per trade (% of balance)
input double    InpStopLossPct     = 1.0;           // Stop-loss percentage (%)
input int       InpCrossConfBars   = 3;             // Bars to confirm EMA cross
input int       InpMagicNumber     = 20260309;      // Magic number
input string    InpOrderComment    = "EMA Conv";     // Order comment
input bool      InpShowThreshold   = true;          // Show threshold visualization
input color     InpThresholdBuyClr = clrDodgerBlue; // Threshold color (buy side)
input color     InpThresholdSellClr= clrOrangeRed;  // Threshold color (close side)

//--- Time filter parameters
input bool              InpUseTimeFilter    = false;  // Enable time filter
input bool              InpTradeSunday      = false;  // Trade on Sunday
input bool              InpTradeMonday      = true;   // Trade on Monday
input bool              InpTradeTuesday     = true;   // Trade on Tuesday
input bool              InpTradeWednesday   = true;   // Trade on Wednesday
input bool              InpTradeThursday    = true;   // Trade on Thursday
input bool              InpTradeFriday      = true;   // Trade on Friday
input bool              InpTradeSaturday    = false;  // Trade on Saturday
input ENUM_TRADE_HOUR   InpStartHour        = H09;    // Trading start hour
input ENUM_TRADE_MINUTE InpStartMinute      = M30;    // Trading start minute
input ENUM_TRADE_HOUR   InpStopHour         = H17;    // Trading stop hour
input ENUM_TRADE_MINUTE InpStopMinute       = M00;    // Trading stop minute

//--- Global handles and buffers
int      g_handleFastEMA;
int      g_handleSlowEMA;
CTrade   g_trade;

//--- State tracking
bool     g_slRemovedBuy = false;

//--- Effective thresholds (resolved from mode)
double   g_buyThreshold;
double   g_closeThreshold;

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   g_handleFastEMA = iMA(_Symbol, PERIOD_CURRENT, InpFastPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_handleSlowEMA = iMA(_Symbol, PERIOD_CURRENT, InpSlowPeriod, 0, MODE_EMA, PRICE_CLOSE);

   if(g_handleFastEMA == INVALID_HANDLE || g_handleSlowEMA == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create EMA indicator handles");
      return INIT_FAILED;
   }

   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(10);

   //--- Resolve effective thresholds
   if(InpThresholdMode == THRESHOLD_UNIFIED)
   {
      g_buyThreshold   = InpThreshold;
      g_closeThreshold = InpThreshold;
   }
   else
   {
      g_buyThreshold   = InpBuyThreshold;
      g_closeThreshold = InpCloseThreshold;
   }

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_handleFastEMA != INVALID_HANDLE) IndicatorRelease(g_handleFastEMA);
   if(g_handleSlowEMA != INVALID_HANDLE) IndicatorRelease(g_handleSlowEMA);

   // Clean up chart objects
   ObjectsDeleteAll(0, "EMA_CONV_");
}

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
{
   // Only run on new bar
   static datetime lastBarTime = 0;
   datetime        currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(currentBarTime == lastBarTime)
      return;
   lastBarTime = currentBarTime;

   //--- Read EMA values for bars 0, 1, 2
   double fast[3], slow[3];
   if(CopyBuffer(g_handleFastEMA, 0, 0, 3, fast) < 3) return;
   if(CopyBuffer(g_handleSlowEMA, 0, 0, 3, slow) < 3) return;

   // CopyBuffer returns oldest-first: index 0 = bar 2, 1 = bar 1, 2 = bar 0
   double fastEMA0 = fast[2]; // current bar
   double fastEMA1 = fast[1]; // previous bar
   double fastEMA2 = fast[0]; // two bars ago

   double slowEMA0 = slow[2];
   double slowEMA1 = slow[1];
   double slowEMA2 = slow[0];

   //--- Calculate gaps
   double gap0 = slowEMA0 - fastEMA0; // current
   double gap1 = slowEMA1 - fastEMA1; // previous
   double gap2 = slowEMA2 - fastEMA2; // two bars ago

   //--- Calculate threshold value for BUY side (fast below slow)
   double buyThresholdVal = 0;
   if(gap2 > 0 && gap1 > 0 && gap0 > 0)
   {
      if(MathAbs(gap2) > 1e-10 && MathAbs(gap1) > 1e-10)
      {
         double ratioPrev = gap1 / gap2;
         double ratioCurr = gap0 / gap1;
         if(ratioPrev < 1.0 && ratioCurr < 1.0)
            buyThresholdVal = ratioPrev - ratioCurr;
      }
   }

   //--- Check for BUY signal (only within trading window)
   if(buyThresholdVal >= g_buyThreshold && IsWithinTradingWindow())
   {
      if(!HasOpenPosition(POSITION_TYPE_BUY))
      {
         double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double sl   = NormalizeDouble(ask * (1.0 - InpStopLossPct / 100.0), _Digits);
         double lots = CalculateLotSize(ask, sl);

         if(lots > 0 && g_trade.Buy(lots, _Symbol, ask, sl, 0, InpOrderComment))
         {
            g_slRemovedBuy = false;
            Print("BUY signal: threshold=", buyThresholdVal, " lots=", lots);
         }
      }
   }

   //--- Calculate threshold value for CLOSE side (fast above slow)
   double closeThresholdVal = 0;
   if(gap2 < 0 && gap1 < 0 && gap0 < 0)
   {
      double absGap0 = MathAbs(gap0);
      double absGap1 = MathAbs(gap1);
      double absGap2 = MathAbs(gap2);

      if(absGap2 > 1e-10 && absGap1 > 1e-10)
      {
         double ratioPrev = absGap1 / absGap2;
         double ratioCurr = absGap0 / absGap1;
         if(ratioPrev < 1.0 && ratioCurr < 1.0)
            closeThresholdVal = ratioPrev - ratioCurr;
      }
   }

   //--- Check for CLOSE signal
   if(closeThresholdVal >= g_closeThreshold)
   {
      if(CloseAllBuyPositions())
         Print("CLOSE signal: threshold=", closeThresholdVal);
   }

   //--- Manage stop-loss removal after confirmed EMA cross
   ManageStopLoss(fastEMA0, fastEMA1, slowEMA0, slowEMA1);

   //--- Visualization: draw threshold bars on chart
   if(InpShowThreshold)
      DrawThresholdBar(currentBarTime, buyThresholdVal, closeThresholdVal);
}

//+------------------------------------------------------------------+
//| Check if current time is within the allowed trading window       |
//+------------------------------------------------------------------+
bool IsWithinTradingWindow()
{
   if(!InpUseTimeFilter)
      return true;

   MqlDateTime dt;
   TimeCurrent(dt);

   //--- Day of week filter (per-day toggle)
   switch(dt.day_of_week)
   {
      case 0: if(!InpTradeSunday)    return false; break;
      case 1: if(!InpTradeMonday)    return false; break;
      case 2: if(!InpTradeTuesday)   return false; break;
      case 3: if(!InpTradeWednesday) return false; break;
      case 4: if(!InpTradeThursday)  return false; break;
      case 5: if(!InpTradeFriday)    return false; break;
      case 6: if(!InpTradeSaturday)  return false; break;
   }

   //--- Time of day filter
   int currentMinutes = dt.hour * 60 + dt.min;
   int startMinutes   = (int)InpStartHour * 60 + (int)InpStartMinute;
   int stopMinutes    = (int)InpStopHour  * 60 + (int)InpStopMinute;

   if(startMinutes <= stopMinutes)
   {
      if(currentMinutes < startMinutes || currentMinutes >= stopMinutes)
         return false;
   }
   else // wraps past midnight, e.g. 22:00 -> 06:00
   {
      if(currentMinutes < startMinutes && currentMinutes >= stopMinutes)
         return false;
   }

   return true;
}

//+------------------------------------------------------------------+
//| Check if we already have an open position of the given type      |
//+------------------------------------------------------------------+
bool HasOpenPosition(ENUM_POSITION_TYPE type)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == type)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Manage stop-loss: remove SL once EMA cross confirmed by N bars   |
//+------------------------------------------------------------------+
void ManageStopLoss(double fastNow, double fastPrev, double slowNow, double slowPrev)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;

      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(posType != POSITION_TYPE_BUY) continue;

      double currentSL = PositionGetDouble(POSITION_SL);

      // Skip if SL is already removed (set to 0)
      if(currentSL == 0)
         continue;

      //--- BUY position: remove SL when fast > slow confirmed for N consecutive bars
      if(IsCrossConfirmed(true))
      {
         double tp = PositionGetDouble(POSITION_TP);
         if(g_trade.PositionModify(ticket, 0, tp))
         {
            Print("BUY SL removed: EMA bullish cross confirmed for ", InpCrossConfBars, " bars");
            g_slRemovedBuy = true;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Close all open BUY positions for this symbol and magic           |
//+------------------------------------------------------------------+
bool CloseAllBuyPositions()
{
   bool closed = false;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_BUY) continue;

      if(g_trade.PositionClose(ticket))
      {
         Print("Closed BUY position #", ticket);
         closed = true;
      }
   }
   return closed;
}

//+------------------------------------------------------------------+
//| Check if EMA cross is confirmed for N consecutive bars           |
//| isBuy=true: check fast > slow for N bars                         |
//| isBuy=false: check fast < slow for N bars                        |
//+------------------------------------------------------------------+
bool IsCrossConfirmed(bool isBuy)
{
   double fast[], slow[];
   int needed = InpCrossConfBars + 1; // +1 because we start from bar 0 (current forming)

   if(CopyBuffer(g_handleFastEMA, 0, 0, needed, fast) < needed) return false;
   if(CopyBuffer(g_handleSlowEMA, 0, 0, needed, slow) < needed) return false;

   // Check the most recent N completed bars (indices 1..N in newest-last order)
   // CopyBuffer returns oldest-first, so newest = index [needed-1]
   for(int j = 0; j < InpCrossConfBars; j++)
   {
      int idx = needed - 1 - j; // from newest to oldest
      if(isBuy)
      {
         if(fast[idx] <= slow[idx])
            return false; // fast must be above slow
      }
      else
      {
         if(fast[idx] >= slow[idx])
            return false; // fast must be below slow
      }
   }

   return true;
}

//+------------------------------------------------------------------+
//| Calculate lot size based on risk % of balance                    |
//| Risk amount = Balance * RiskPct / 100                            |
//| SL distance in money per lot = (entry - sl) * contract_size     |
//| Lots = risk_amount / sl_distance_per_lot                         |
//+------------------------------------------------------------------+
double CalculateLotSize(double entryPrice, double slPrice)
{
   double balance      = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount   = balance * InpRiskPct / 100.0;
   double slDistance    = MathAbs(entryPrice - slPrice);

   if(slDistance < _Point)
      return 0;

   double contractSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   double costPerLot   = slDistance * contractSize;

   if(costPerLot <= 0)
      return 0;

   double lots = riskAmount / costPerLot;

   // Clamp to broker limits
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lots = MathFloor(lots / lotStep) * lotStep;
   if(lots < minLot) lots = minLot;
   if(lots > maxLot) lots = maxLot;

   return NormalizeDouble(lots, 2);
}

//+------------------------------------------------------------------+
//| Draw threshold value as a histogram bar on the chart             |
//| Uses a separate sub-window style via OBJ_HISTOGRAM objects       |
//| placed at the bottom of the main chart.                          |
//+------------------------------------------------------------------+
void DrawThresholdBar(datetime time, double buyVal, double closeVal)
{
   // Draw BUY-side threshold (positive, blue)
   if(buyVal > 0)
   {
      string name = "EMA_CONV_THR_BUY_" + TimeToString(time, TIME_DATE | TIME_SECONDS);
      double low  = iLow(_Symbol, PERIOD_CURRENT, 0);
      double range = iHigh(_Symbol, PERIOD_CURRENT, 0) - low;
      if(range <= 0) range = _Point * 100;

      // Use the larger threshold for consistent scaling
      double maxThr = MathMax(g_buyThreshold, g_closeThreshold);
      double scaleFactor = (range * 0.3) / maxThr;
      double barHeight   = buyVal * scaleFactor;
      double basePrice   = low - range * 0.15;

      // Vertical line from base to base+height
      if(ObjectCreate(0, name, OBJ_TREND, 0, time, basePrice, time, basePrice + barHeight))
      {
         ObjectSetInteger(0, name, OBJPROP_COLOR, InpThresholdBuyClr);
         ObjectSetInteger(0, name, OBJPROP_WIDTH, 4);
         ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
         ObjectSetInteger(0, name, OBJPROP_RAY_LEFT, false);
         ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
      }

      // BUY threshold trigger line
      string thrLineBuy = "EMA_CONV_THR_LINE_BUY";
      double thrPriceBuy = basePrice + g_buyThreshold * scaleFactor;
      if(!ObjectFind(0, thrLineBuy))
         ObjectCreate(0, thrLineBuy, OBJ_HLINE, 0, 0, thrPriceBuy);
      ObjectSetDouble(0, thrLineBuy, OBJPROP_PRICE, thrPriceBuy);
      ObjectSetInteger(0, thrLineBuy, OBJPROP_COLOR, InpThresholdBuyClr);
      ObjectSetInteger(0, thrLineBuy, OBJPROP_STYLE, STYLE_DOT);
      ObjectSetInteger(0, thrLineBuy, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, thrLineBuy, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, thrLineBuy, OBJPROP_HIDDEN, true);
   }

   // Draw CLOSE-side threshold (negative direction, red)
   if(closeVal > 0)
   {
      string name = "EMA_CONV_THR_CLS_" + TimeToString(time, TIME_DATE | TIME_SECONDS);
      double low  = iLow(_Symbol, PERIOD_CURRENT, 0);
      double range = iHigh(_Symbol, PERIOD_CURRENT, 0) - low;
      if(range <= 0) range = _Point * 100;

      double maxThr = MathMax(g_buyThreshold, g_closeThreshold);
      double scaleFactor = (range * 0.3) / maxThr;
      double barHeight   = closeVal * scaleFactor;
      double basePrice   = low - range * 0.15;

      // Draw downward from base
      if(ObjectCreate(0, name, OBJ_TREND, 0, time, basePrice, time, basePrice - barHeight))
      {
         ObjectSetInteger(0, name, OBJPROP_COLOR, InpThresholdSellClr);
         ObjectSetInteger(0, name, OBJPROP_WIDTH, 4);
         ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
         ObjectSetInteger(0, name, OBJPROP_RAY_LEFT, false);
         ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
      }

      // CLOSE threshold trigger line
      string thrLineClose = "EMA_CONV_THR_LINE_CLOSE";
      double thrPriceClose = basePrice - g_closeThreshold * scaleFactor;
      if(!ObjectFind(0, thrLineClose))
         ObjectCreate(0, thrLineClose, OBJ_HLINE, 0, 0, thrPriceClose);
      ObjectSetDouble(0, thrLineClose, OBJPROP_PRICE, thrPriceClose);
      ObjectSetInteger(0, thrLineClose, OBJPROP_COLOR, InpThresholdSellClr);
      ObjectSetInteger(0, thrLineClose, OBJPROP_STYLE, STYLE_DOT);
      ObjectSetInteger(0, thrLineClose, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, thrLineClose, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, thrLineClose, OBJPROP_HIDDEN, true);
   }

   // Comment on chart with current threshold values
   string info = StringFormat("BUY: %.4f / %.4f   CLOSE: %.4f / %.4f",
                              buyVal, g_buyThreshold, closeVal, g_closeThreshold);
   Comment(info);
}
//+------------------------------------------------------------------+
