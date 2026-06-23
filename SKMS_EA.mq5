//+------------------------------------------------------------------+
//|  SK Market Structure EA                                          |
//|  XAUUSD M1 - Liquidity Sweep Strategy                           |
//+------------------------------------------------------------------+
#property copyright "SK"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//--- Input Parameters
input double LotSize       = 0.05;
input int    MagicNumber   = 12345;
input double SL_Buffer     = 1.0;   // 10 pips for XAUUSD

//--- Trade object
CTrade trade;

//+------------------------------------------------------------------+
//|  ENUMS                                                           |
//+------------------------------------------------------------------+
enum BIAS { BULLISH, BEARISH };

//+------------------------------------------------------------------+
//|  STRUCTS                                                         |
//+------------------------------------------------------------------+
struct Pivot
{
   double price;
   bool   confirmed;
   int    barIndex;

   Pivot() : price(0), confirmed(false), barIndex(0) {}
   Pivot(double p, bool c = false, int b = 0) : price(p), confirmed(c), barIndex(b) {}
};

struct IndependentBar
{
   double level;  // low for bullish, high for bearish
   int    barIndex;

   IndependentBar() : level(0), barIndex(0) {}
   IndependentBar(double l, int b = 0) : level(l), barIndex(b) {}
};

//+------------------------------------------------------------------+
//|  GLOBAL STATE - Indicator Variables                             |
//+------------------------------------------------------------------+
BIAS   swingBias;
Pivot  lastHigh, lastLow;
Pivot  confirmHigh, confirmLow;
IndependentBar lastIndBullBar, lastIndBearBar;
bool   retracementStarted;
double retracementStartLevel;

//+------------------------------------------------------------------+
//|  GLOBAL STATE - Strategy Variables                              |
//+------------------------------------------------------------------+
bool   bearishChochActive;
bool   bullishChochActive;
bool   isBocNearToSweep;
double bocHigh;
double bocLow;
double chochLevel;
double tpLevel;
double trackedBocHigh;
double trackedBocLow;
double absoluteSlPoint;
int    independentBarsAfterBoc;
int    independentBarsAllowed;

//+------------------------------------------------------------------+
//|  BAR TRACKING                                                   |
//+------------------------------------------------------------------+
datetime lastBarTime;
int      totalBars;

//+------------------------------------------------------------------+
//|  HELPER: Get bar index from time (bars ago from current)        |
//+------------------------------------------------------------------+
// We store barIndex as absolute counted bars since EA started
// current bar = totalBars, older bars = totalBars - barsAgo

//+------------------------------------------------------------------+
//|  HELPER: Lowest Low between two bar indices                     |
//+------------------------------------------------------------------+
void GetLowestLow(int fromBarIdx, int toBarIdx, double &lowestLow, int &lowestBarIdx)
{
   lowestLow    = DBL_MAX;
   lowestBarIdx = fromBarIdx;

   for(int i = fromBarIdx; i <= toBarIdx; i++)
   {
      int barsAgo = totalBars - i;
      if(barsAgo < 0) continue;
      double l = iLow(_Symbol, PERIOD_CURRENT, barsAgo);
      if(l < lowestLow)
      {
         lowestLow    = l;
         lowestBarIdx = i;
      }
   }
}

//+------------------------------------------------------------------+
//|  HELPER: Highest High between two bar indices                   |
//+------------------------------------------------------------------+
void GetHighestHigh(int fromBarIdx, int toBarIdx, double &highestHigh, int &highestBarIdx)
{
   highestHigh    = -DBL_MAX;
   highestBarIdx  = fromBarIdx;

   for(int i = fromBarIdx; i <= toBarIdx; i++)
   {
      int barsAgo = totalBars - i;
      if(barsAgo < 0) continue;
      double h = iHigh(_Symbol, PERIOD_CURRENT, barsAgo);
      if(h > highestHigh)
      {
         highestHigh    = h;
         highestBarIdx  = i;
      }
   }
}

//+------------------------------------------------------------------+
//|  HELPER: Validate Bearish CHOCH breakout candle (Buy setup)     |
//|  Cond1: lower wick >= 15% of body                               |
//|  Cond2: less than 75% of body below choch level                 |
//+------------------------------------------------------------------+
bool ValidateBearishChoch(double o, double c, double h, double l, double choch)
{
   double body       = MathAbs(c - o);
   if(body <= 0) return false;

   double lowerWick  = MathMin(o, c) - l;
   bool   cond1      = lowerWick >= body * 0.15;

   double bodyBottom = MathMin(o, c);
   double belowChoch = MathMax(0.0, choch - bodyBottom);
   double pctBelow   = belowChoch / body;
   bool   cond2      = pctBelow < 0.75;

   return cond1 && cond2;
}

//+------------------------------------------------------------------+
//|  HELPER: Validate Bullish CHOCH breakout candle (Sell setup)    |
//|  Cond1: upper wick >= 15% of body                               |
//|  Cond2: less than 75% of body above choch level                 |
//+------------------------------------------------------------------+
bool ValidateBullishChoch(double o, double c, double h, double l, double choch)
{
   double body       = MathAbs(c - o);
   if(body <= 0) return false;

   double upperWick  = h - MathMax(o, c);
   bool   cond1      = upperWick >= body * 0.15;

   double bodyTop    = MathMax(o, c);
   double aboveChoch = MathMax(0.0, bodyTop - choch);
   double pctAbove   = aboveChoch / body;
   bool   cond2      = pctAbove < 0.75;

   return cond1 && cond2;
}

//+------------------------------------------------------------------+
//|  HELPER: Is BOC close near to sweep level                       |
//+------------------------------------------------------------------+
bool CheckIsBocNearToSweep(double breakoutLevel, double o, double c)
{
   double bodySize         = MathAbs(o - c);
   double bodyAcrossBreak  = MathAbs(c - breakoutLevel);
   if(bodySize <= 0) return false;
   return bodyAcrossBreak <= bodySize * 0.01;
}

//+------------------------------------------------------------------+
//|  HELPER: Is next IB after BOC valid (not too far)               |
//+------------------------------------------------------------------+
bool CheckIsValidNextIBAfterBoc(double breakoutLevel, double o, double c, double ratio = 0.4)
{
   double bodySize         = MathAbs(o - c);
   double bodyAcrossBreak  = MathAbs(c - breakoutLevel);
   if(bodySize <= 0) return false;
   return bodyAcrossBreak <= bodySize * ratio;
}

//+------------------------------------------------------------------+
//|  HELPER: Is momentum candle                                     |
//+------------------------------------------------------------------+
bool CheckIsMomentumCandle(double h, double l, double o, double c, double wickPct = 0.35)
{
   bool   isBullish   = c > o;
   double candleSize  = MathAbs(h - l);
   if(candleSize <= 0) return false;
   double candleWick  = isBullish ? h - c : c - l;
   return candleWick <= candleSize * wickPct;
}

//+------------------------------------------------------------------+
//|  HELPER: Is significant breakout                                |
//+------------------------------------------------------------------+
bool CheckIsSignificantBreakout(double breakoutLevel, double h, double l, double o, double c)
{
   double candleSize       = MathAbs(h - l);
   double bodyAcrossBreak  = MathAbs(c - breakoutLevel);
   if(candleSize <= 0) return false;
   return bodyAcrossBreak >= candleSize * 0.1;
}

//+------------------------------------------------------------------+
//|  HELPER: Is trade open by this EA                               |
//+------------------------------------------------------------------+
bool IsTradeOpen()
{
   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(PositionGetSymbol(i) == _Symbol)
         if(PositionGetInteger(POSITION_MAGIC) == MagicNumber)
            return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//|  RESET Buy Setup                                                |
//+------------------------------------------------------------------+
void ResetBuySetup()
{
   bearishChochActive        = false;
   bocHigh                   = 0;
   bocLow                    = 0;
   trackedBocHigh            = 0;
   trackedBocLow             = 0;
   chochLevel                = 0;
   tpLevel                   = 0;
   absoluteSlPoint           = 0;
   isBocNearToSweep          = false;
   independentBarsAfterBoc   = 0;
}

//+------------------------------------------------------------------+
//|  RESET Sell Setup                                               |
//+------------------------------------------------------------------+
void ResetSellSetup()
{
   bullishChochActive        = false;
   bocHigh                   = 0;
   bocLow                    = 0;
   trackedBocHigh            = 0;
   trackedBocLow             = 0;
   chochLevel                = 0;
   tpLevel                   = 0;
   absoluteSlPoint           = 0;
   isBocNearToSweep          = false;
   independentBarsAfterBoc   = 0;
}

//+------------------------------------------------------------------+
//|  INIT                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(10);

   // Initialize state
   swingBias             = BULLISH;
   retracementStarted    = false;
   retracementStartLevel = 0;
   bearishChochActive    = false;
   bullishChochActive    = false;
   isBocNearToSweep      = false;
   bocHigh               = 0;
   bocLow                = 0;
   chochLevel            = 0;
   tpLevel               = 0;
   trackedBocHigh        = 0;
   trackedBocLow         = 0;
   absoluteSlPoint       = 0;
   independentBarsAfterBoc  = 0;
   independentBarsAllowed   = 1;
   totalBars             = 0;
   lastBarTime           = 0;

   // Bootstrap from first available bar
   double o0 = iOpen(_Symbol,  PERIOD_CURRENT, 0);
   double c0 = iClose(_Symbol, PERIOD_CURRENT, 0);
   double h0 = iHigh(_Symbol,  PERIOD_CURRENT, 0);
   double l0 = iLow(_Symbol,   PERIOD_CURRENT, 0);

   if(c0 > o0)
   {
      swingBias    = BULLISH;
      lastHigh     = Pivot(h0, false, 0);
      confirmLow   = Pivot(l0, true,  0);
   }
   else
   {
      swingBias    = BEARISH;
      lastLow      = Pivot(l0, false, 0);
      confirmHigh  = Pivot(h0, true,  0);
   }

   Print("SKMS EA initialized on ", _Symbol);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//|  ONTICK                                                         |
//+------------------------------------------------------------------+
void OnTick()
{
   // Only process on new bar
   datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(currentBarTime == lastBarTime) return;
   lastBarTime = currentBarTime;

   // We process the CLOSED bar (bar index 1 = last closed bar)
   // All OHLC values are from bar[1] (the just-closed candle)
   double O = iOpen(_Symbol,  PERIOD_CURRENT, 1);
   double C = iClose(_Symbol, PERIOD_CURRENT, 1);
   double H = iHigh(_Symbol,  PERIOD_CURRENT, 1);
   double L = iLow(_Symbol,   PERIOD_CURRENT, 1);

   totalBars++;
   int currentBarIdx = totalBars;

   double prevClose = iClose(_Symbol, PERIOD_CURRENT, 2);

   ProcessIndicatorLogic(O, C, H, L, prevClose, currentBarIdx);
   ProcessStrategyExecution(O, C, H, L);
}

//+------------------------------------------------------------------+
//|  INDICATOR LOGIC                                                |
//+------------------------------------------------------------------+
void ProcessIndicatorLogic(double O, double C, double H, double L,
                            double prevClose, int barIdx)
{
   //--- Update last high / last low
   if(swingBias == BULLISH)
   {
      if(C > lastHigh.price && !lastHigh.confirmed)
      {
         lastHigh = Pivot(H, false, barIdx);
         double ibLevel = (O != prevClose) ? prevClose : L;
         lastIndBullBar = IndependentBar(ibLevel, barIdx);
         retracementStartLevel = lastIndBullBar.level;
         retracementStarted    = false;
      }
      else if(H > lastHigh.price && C < lastHigh.price && lastHigh.confirmed)
         lastHigh.price = H;
      else if(H > lastHigh.price && C < lastHigh.price && !lastHigh.confirmed)
         lastHigh = Pivot(H, false, barIdx);
   }
   else if(swingBias == BEARISH)
   {
      if(C < lastLow.price && !lastLow.confirmed)
      {
         lastLow = Pivot(L, false, barIdx);
         double ibLevel = (O != prevClose) ? prevClose : H;
         lastIndBearBar = IndependentBar(ibLevel, barIdx);
         retracementStartLevel = lastIndBearBar.level;
         retracementStarted    = false;
      }
      else if(L < lastLow.price && C > lastLow.price && lastLow.confirmed)
         lastLow.price = L;
      else if(L < lastLow.price && C > lastLow.price && !lastLow.confirmed)
         lastLow = Pivot(L, false, barIdx);
   }

   //--- Update confirm high / confirm low
   if(swingBias == BULLISH)
   {
      if(confirmLow.price > 0 && L < confirmLow.price && C > confirmLow.price && confirmLow.confirmed)
         confirmLow.price = L;
      else if(confirmLow.price > 0 && L < confirmLow.price && C > confirmLow.price && !confirmLow.confirmed)
         confirmLow = Pivot(L, false, barIdx);
   }
   else if(swingBias == BEARISH)
   {
      if(confirmHigh.price > 0 && H > confirmHigh.price && C < confirmHigh.price && confirmHigh.confirmed)
         confirmHigh.price = H;
      else if(confirmHigh.price > 0 && H > confirmHigh.price && C < confirmHigh.price && !confirmHigh.confirmed)
         confirmHigh = Pivot(H, false, barIdx);
   }

   //--- Retracement start check
   if(!retracementStarted && retracementStartLevel > 0)
   {
      if(swingBias == BULLISH)
      {
         if(C < retracementStartLevel)
         {
            retracementStarted    = true;
            retracementStartLevel = 0;
            lastHigh.confirmed    = true;
         }
         else if(L < retracementStartLevel)
            retracementStartLevel = L;
      }
      else if(swingBias == BEARISH)
      {
         if(C > retracementStartLevel)
         {
            retracementStarted    = true;
            retracementStartLevel = 0;
            lastLow.confirmed     = true;
         }
         else if(H > retracementStartLevel)
            retracementStartLevel = H;
      }
   }

   //--- BOS / CHOCH Detection
   if(retracementStarted)
   {
      if(swingBias == BULLISH)
      {
         // BEARISH CHOCH → Buy setup
         if(confirmLow.price > 0 && C < confirmLow.price && confirmLow.confirmed)
         {
            Print("Bearish CHOCH detected at ", confirmLow.price);

            double hh; int hhBar;
            GetHighestHigh(confirmLow.barIndex, barIdx, hh, hhBar);
            confirmHigh = Pivot(hh, true, hhBar);

            if(!bearishChochActive && !bullishChochActive && !IsTradeOpen())
            {
               bearishChochActive  = true;
               bullishChochActive  = false;
               chochLevel          = confirmLow.price;
               tpLevel             = confirmHigh.price;
               bocHigh             = H;
               bocLow              = L;
               trackedBocHigh      = H;
               trackedBocLow       = L;
               absoluteSlPoint     = L;
               isBocNearToSweep    = CheckIsBocNearToSweep(chochLevel, O, C);
               independentBarsAfterBoc = 0;

               bool valid = ValidateBearishChoch(O, C, H, L, chochLevel);
               if(!valid)
               {
                  Print("BOC validation failed, resetting buy setup");
                  ResetBuySetup();
               }
            }

            swingBias             = BEARISH;
            lastLow               = Pivot(L, false, barIdx);
            retracementStarted    = false;
            lastIndBearBar        = IndependentBar(H, barIdx);
            retracementStartLevel = lastIndBearBar.level;
         }
         // BULLISH BOS
         else if(lastHigh.price > 0 && C > lastHigh.price && lastHigh.confirmed)
         {
            Print("Bullish BOS at ", lastHigh.price);

            double ll; int llBar;
            GetLowestLow(lastHigh.barIndex, barIdx, ll, llBar);
            confirmLow            = Pivot(ll, true, llBar);
            lastHigh              = Pivot(H, false, barIdx);
            retracementStarted    = false;
            lastIndBullBar        = IndependentBar(L, barIdx);
            retracementStartLevel = lastIndBullBar.level;
         }
      }
      else if(swingBias == BEARISH)
      {
         // BULLISH CHOCH → Sell setup
         if(confirmHigh.price > 0 && C > confirmHigh.price && confirmHigh.confirmed)
         {
            Print("Bullish CHOCH detected at ", confirmHigh.price);

            double ll; int llBar;
            GetLowestLow(confirmHigh.barIndex, barIdx, ll, llBar);
            confirmLow = Pivot(ll, true, llBar);

            if(!bullishChochActive && !bearishChochActive && !IsTradeOpen())
            {
               bullishChochActive  = true;
               bearishChochActive  = false;
               chochLevel          = confirmHigh.price;
               tpLevel             = confirmLow.price;
               bocHigh             = H;
               bocLow              = L;
               trackedBocHigh      = H;
               trackedBocLow       = L;
               absoluteSlPoint     = H;
               isBocNearToSweep    = CheckIsBocNearToSweep(chochLevel, O, C);
               independentBarsAfterBoc = 0;

               bool valid = ValidateBullishChoch(O, C, H, L, chochLevel);
               if(!valid)
               {
                  Print("BOC validation failed, resetting sell setup");
                  ResetSellSetup();
               }
            }

            swingBias             = BULLISH;
            lastHigh              = Pivot(H, false, barIdx);
            retracementStarted    = false;
            lastIndBullBar        = IndependentBar(L, barIdx);
            retracementStartLevel = lastIndBullBar.level;
         }
         // BEARISH BOS
         else if(lastLow.price > 0 && C < lastLow.price && lastLow.confirmed)
         {
            Print("Bearish BOS at ", lastLow.price);

            double hh; int hhBar;
            GetHighestHigh(lastLow.barIndex, barIdx, hh, hhBar);
            confirmHigh           = Pivot(hh, true, hhBar);
            lastLow               = Pivot(L, false, barIdx);
            retracementStarted    = false;
            lastIndBearBar        = IndependentBar(H, barIdx);
            retracementStartLevel = lastIndBearBar.level;
         }
      }
   }
   else
   {
      // No retracement: direct confirmHigh/Low breaks
      if(swingBias == BULLISH && confirmLow.price > 0 && C < confirmLow.price)
      {
         swingBias             = BEARISH;
         confirmHigh           = lastHigh;
         confirmHigh.confirmed = true;
         lastLow               = confirmLow;
         confirmLow            = Pivot(0, false, 0);
         lastHigh              = Pivot(0, false, 0);
         lastIndBullBar        = IndependentBar(L, barIdx);
         retracementStartLevel = lastIndBullBar.level;
         retracementStarted    = false;
      }
      else if(swingBias == BEARISH && confirmHigh.price > 0 && C > confirmHigh.price)
      {
         swingBias             = BULLISH;
         confirmLow            = lastLow;
         confirmLow.confirmed  = true;
         lastHigh              = confirmHigh;
         confirmHigh           = Pivot(0, false, 0);
         lastLow               = Pivot(0, false, 0);
         lastIndBearBar        = IndependentBar(H, barIdx);
         retracementStartLevel = lastIndBearBar.level;
         retracementStarted    = false;
      }
   }
}

//+------------------------------------------------------------------+
//|  STRATEGY EXECUTION                                             |
//+------------------------------------------------------------------+
void ProcessStrategyExecution(double O, double C, double H, double L)
{
   bool isBullishCandle = C > O;
   bool isBearishCandle = C < O;

   //=================================================================
   // BUY SETUP (after Bearish CHOCH)
   //=================================================================
   if(bearishChochActive && !IsTradeOpen())
   {
      // Cond3: breakout candle low broken → cancel
      if(C < trackedBocLow && O > trackedBocLow)
      {
         independentBarsAfterBoc++;

         int maxAllowed = isBocNearToSweep
                        ? independentBarsAllowed + 1
                        : independentBarsAllowed;

         bool tooManyBars   = independentBarsAfterBoc > maxAllowed;
         bool invalidIB     = (!isBocNearToSweep
                               && !CheckIsValidNextIBAfterBoc(trackedBocLow, O, C)
                               && independentBarsAfterBoc == 1);
         bool isMomentum    = CheckIsMomentumCandle(H, L, O, C);

         if(tooManyBars || invalidIB || isMomentum)
         {
            Print("Buy setup cancelled - low broken invalidation");
            ResetBuySetup();
         }
         else
         {
            trackedBocLow   = L;
            absoluteSlPoint = L;
            if(isBocNearToSweep && independentBarsAfterBoc == 1)
               trackedBocHigh = H;
         }
      }
      else
      {
         // Sweep of tracked low
         if(L < trackedBocLow && C > trackedBocLow)
         {
            trackedBocLow   = L;
            absoluteSlPoint = L;
         }

         // Entry: close above tracked high
         if(C > trackedBocHigh && H > trackedBocHigh)
         {
            if(CheckIsMomentumCandle(H, L, O, C, 0.3)
               && CheckIsSignificantBreakout(trackedBocHigh, H, L, O, C)
               && isBullishCandle)
            {
               double sl = absoluteSlPoint - SL_Buffer;
               double tp = tpLevel;

               Print("BUY entry at ", C, " SL=", sl, " TP=", tp);
               if(trade.Buy(LotSize, _Symbol, 0, sl, tp, "BUY @ CHOCH"))
                  Print("Buy order placed successfully");
               else
                  Print("Buy order failed: ", trade.ResultRetcode());

               ResetBuySetup();
            }
            else
            {
               // High swept but entry conditions not met → update tracked high
               trackedBocHigh = H;
            }
         }
         else if(H > trackedBocHigh && C < trackedBocHigh)
         {
            // Wick above tracked high → update level
            trackedBocHigh = H;
         }
      }
   }

   //=================================================================
   // SELL SETUP (after Bullish CHOCH)
   //=================================================================
   if(bullishChochActive && !IsTradeOpen())
   {
      // Cond3: breakout candle high broken → cancel
      if(C > trackedBocHigh && O < trackedBocHigh)
      {
         independentBarsAfterBoc++;

         int maxAllowed = isBocNearToSweep
                        ? independentBarsAllowed + 1
                        : independentBarsAllowed;

         bool tooManyBars   = independentBarsAfterBoc > maxAllowed;
         bool invalidIB     = (!isBocNearToSweep
                               && !CheckIsValidNextIBAfterBoc(chochLevel, O, C)
                               && independentBarsAfterBoc == 0);
         bool isMomentum    = CheckIsMomentumCandle(H, L, O, C, 0.2);

         if(tooManyBars || invalidIB || isMomentum)
         {
            Print("Sell setup cancelled - high broken invalidation");
            ResetSellSetup();
         }
         else
         {
            trackedBocHigh  = H;
            absoluteSlPoint = H;
            if(isBocNearToSweep && independentBarsAfterBoc == 1)
               trackedBocHigh = H;
         }
      }
      else
      {
         // Sweep of tracked high
         if(H > trackedBocHigh && C < trackedBocHigh)
         {
            trackedBocHigh  = H;
            absoluteSlPoint = H;
         }

         // Entry: close below tracked low
         if(C < trackedBocLow && L < trackedBocLow)
         {
            if(CheckIsMomentumCandle(H, L, O, C, 0.38)
               && CheckIsSignificantBreakout(trackedBocLow, H, L, O, C)
               && isBearishCandle)
            {
               double sl = absoluteSlPoint + SL_Buffer;
               double tp = tpLevel;

               Print("SELL entry at ", C, " SL=", sl, " TP=", tp);
               if(trade.Sell(LotSize, _Symbol, 0, sl, tp, "SELL @ CHOCH"))
                  Print("Sell order placed successfully");
               else
                  Print("Sell order failed: ", trade.ResultRetcode());

               ResetSellSetup();
            }
            else
            {
               trackedBocLow = L;
            }
         }
         else if(L < trackedBocLow && C > trackedBocLow)
         {
            // Wick below tracked low → update level
            trackedBocLow = L;
         }
      }
   }
}

//+------------------------------------------------------------------+
//|  DEINIT                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("SKMS EA removed. Reason: ", reason);
}
//+------------------------------------------------------------------+
