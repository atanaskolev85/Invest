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

//--- Input parameters
input int       InpFastPeriod      = 12;           // Fast EMA period
input int       InpSlowPeriod      = 26;           // Slow EMA period
input double    InpThreshold       = 0.05;         // Convergence acceleration threshold
input double    InpLotSize         = 0.1;           // Lot size
input double    InpStopLossPct     = 1.0;           // Stop-loss percentage (%)
input int       InpCrossConfBars   = 3;             // Bars to confirm EMA cross
input int       InpMagicNumber     = 20260309;      // Magic number
input color     InpBuyArrowColor   = clrDodgerBlue; // Buy arrow color
input color     InpCloseArrowColor = clrOrangeRed;  // Close arrow color

//--- Global handles and buffers
int      g_handleFastEMA;
int      g_handleSlowEMA;
CTrade   g_trade;

//--- State tracking
bool     g_slRemovedBuy = false;

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

   //--- Check for BUY signal (fast below slow, converging)
   if(gap2 > 0 && gap1 > 0 && gap0 > 0) // fast is below slow for all 3 bars
   {
      if(MathAbs(gap2) > 1e-10 && MathAbs(gap1) > 1e-10) // division-by-zero protection
      {
         double ratioPrev = gap1 / gap2;
         double ratioCurr = gap0 / gap1;

         if(ratioPrev < 1.0 && ratioCurr < 1.0) // converging for 2 consecutive bars
         {
            if((ratioPrev - ratioCurr) >= InpThreshold) // acceleration
            {
               if(!HasOpenPosition(POSITION_TYPE_BUY))
               {
                  double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
                  double sl  = NormalizeDouble(ask * (1.0 - InpStopLossPct / 100.0), _Digits);

                  if(g_trade.Buy(InpLotSize, _Symbol, ask, sl, 0, "EMA Conv BUY"))
                  {
                     g_slRemovedBuy = false;
                     DrawArrow("EMA_CONV_BUY_", currentBarTime, iLow(_Symbol, PERIOD_CURRENT, 0),
                               InpBuyArrowColor, 233, true); // arrow up
                     Print("BUY signal: ratioPrev=", ratioPrev, " ratioCurr=", ratioCurr,
                           " diff=", ratioPrev - ratioCurr);
                  }
               }
            }
         }
      }
   }

   //--- Check for CLOSE signal (reverse of buy: fast above slow, diverging)
   // In invest mode we close the long position instead of opening a short
   if(gap2 < 0 && gap1 < 0 && gap0 < 0) // fast is above slow for all 3 bars
   {
      double absGap0 = MathAbs(gap0);
      double absGap1 = MathAbs(gap1);
      double absGap2 = MathAbs(gap2);

      if(absGap2 > 1e-10 && absGap1 > 1e-10) // division-by-zero protection
      {
         double ratioPrev = absGap1 / absGap2;
         double ratioCurr = absGap0 / absGap1;

         if(ratioPrev < 1.0 && ratioCurr < 1.0) // converging downward for 2 consecutive bars
         {
            if((ratioPrev - ratioCurr) >= InpThreshold) // acceleration
            {
               if(CloseAllBuyPositions())
               {
                  DrawArrow("EMA_CONV_CLOSE_", currentBarTime, iHigh(_Symbol, PERIOD_CURRENT, 0),
                            InpCloseArrowColor, 234, false); // arrow down
                  Print("CLOSE signal: ratioPrev=", ratioPrev, " ratioCurr=", ratioCurr,
                        " diff=", ratioPrev - ratioCurr);
               }
            }
         }
      }
   }

   //--- Manage stop-loss removal after confirmed EMA cross
   ManageStopLoss(fastEMA0, fastEMA1, slowEMA0, slowEMA1);
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
//| Draw signal arrow on the chart                                   |
//+------------------------------------------------------------------+
void DrawArrow(string prefix, datetime time, double price, color clr, int arrowCode, bool isBuy)
{
   string name = prefix + TimeToString(time, TIME_DATE | TIME_SECONDS);

   // Offset the arrow slightly from the candle
   double offset = SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 20;
   if(isBuy)
      price -= offset;
   else
      price += offset;

   if(ObjectCreate(0, name, OBJ_ARROW, 0, time, price))
   {
      ObjectSetInteger(0, name, OBJPROP_ARROWCODE, arrowCode);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   }
}
//+------------------------------------------------------------------+
