//+------------------------------------------------------------------+
//|  Sandwich Pattern EA                                             |
//|  3-Candle Pattern with SMA200 Direction Filter                  |
//+------------------------------------------------------------------+
#property copyright "SK"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//--- Inputs
enum LOT_MODE
{
   FIXED_LOT,   // Fixed Lot Size
   FIXED_RISK   // Fixed Risk (Account Currency)
};

input LOT_MODE LotMode              = FIXED_LOT; // Lot Mode
input double   FixedLot             = 0.05;       // Fixed Lot Size
input double   RiskAmount           = 50.0;       // Risk Amount (Account Currency)
input int      MagicNumber          = 12345;
input double   RR                   = 2.0;        // Risk:Reward Ratio
input bool     UseBE                = true;       // Break Even (ON/OFF)
input double   BE_RR                = 1.0;        // Break Even at RR
input double   DojiBodyPct          = 20;       // Doji: max body % of candle size
input double   MomentumWickPct      = 15.0;       // Momentum candle: max wick %
input double   C1BodyMinPct         = 50.0;       // C1: min body % of candle size
input double   C1WickMaxPct         = 30.0;       // C1: max upper/lower wick %
input int      SMA_Period           = 200;        // SMA Period for direction
input bool     DojiRangeProtction   = false;

CTrade trade;

//+------------------------------------------------------------------+
//|  ENUMS                                                          |
//+------------------------------------------------------------------+
enum SETUP_STATE
{
   IDLE,        // no pattern being tracked
   WAIT_C2,     // C1 found, waiting for doji
   WAIT_C3,     // C2 (doji) found, waiting for momentum candle
   WAIT_RETEST  // C3 confirmed, waiting for retest of doji high/low
};

//+------------------------------------------------------------------+
//|  GLOBAL STATE                                                   |
//+------------------------------------------------------------------+

// Buy setup
SETUP_STATE buyState;
double      buyC1High, buyC1Low;
double      buyC2High, buyC2Low;   // doji high/low
double      buyC3Close;            // C3 close price
double      buySlLevel;            // SL = C1 low
double      buyRetestLevel;        // entry trigger = doji high
double      buyExpireLevel;        // upper bound = C3close + d

// Sell setup
SETUP_STATE sellState;
double      sellC1High, sellC1Low;
double      sellC2High, sellC2Low; // doji high/low
double      sellC3Close;
double      sellSlLevel;           // SL = C1 high
double      sellRetestLevel;       // entry trigger = doji low
double      sellExpireLevel;       // lower bound = C3close - d

// Trade state for BE
bool        inTrade;
bool        bePlaced;
double      entryPrice;
double      slPrice;
double      tpPrice;
double      bePrice;

// SMA handle
int         hSMA;

// Bar tracking (for bar-close logic)
datetime    lastBarTime;

//+------------------------------------------------------------------+
//|  CANDLE HELPERS                                                 |
//+------------------------------------------------------------------+
bool   IsBullish(double o, double c)              { return c > o; }
bool   IsBearish(double o, double c)              { return c < o; }
double CandleSize(double h, double l)             { return h - l; }
double BodySize(double o, double c)               { return MathAbs(c - o); }
double UpperWick(double h, double o, double c)    { return h - MathMax(o, c); }
double LowerWick(double l, double o, double c)    { return MathMin(o, c) - l; }

// C1 bullish: body >= C1BodyMinPct%, upper wick <= C1WickMaxPct%
bool IsValidC1Bullish(double h, double l, double o, double c)
{
   if(!IsBullish(o, c)) return false;
   double cs = CandleSize(h, l);
   if(cs <= 0) return false;
   bool bodySizeValid = BodySize(o,c)/cs*100.0 >= C1BodyMinPct;
   bool upperWickValid = UpperWick(h,o,c)/cs*100.0 <= C1WickMaxPct;
   return (bodySizeValid);
}

// C1 bearish: body >= C1BodyMinPct%, lower wick <= C1WickMaxPct%
bool IsValidC1Bearish(double h, double l, double o, double c)
{
   if(!IsBearish(o, c)) return false;
   double cs = CandleSize(h, l);
   if(cs <= 0) return false;
   bool bodySizeValid = BodySize(o,c)/cs*100.0 >= C1BodyMinPct;
   bool lowerWickValid = LowerWick(l,o,c)/cs*100.0 <= C1WickMaxPct;
   return (bodySizeValid);
}

// Doji bullish: bullish + body <= DojiBodyPct%
bool IsValidDojiBullish(double h, double l, double o, double c)
{
   if(!IsBullish(o, c)) return false;
   double cs = CandleSize(h, l);
   if(cs <= 0) return false;
   return BodySize(o,c)/cs*100.0 <= DojiBodyPct;
}

// Doji bearish: bearish + body <= DojiBodyPct%
bool IsValidDojiBearish(double h, double l, double o, double c)
{
   if(!IsBearish(o, c)) return false;
   double cs = CandleSize(h, l);
   if(cs <= 0) return false;
   return BodySize(o,c)/cs*100.0 <= DojiBodyPct;
}

// Momentum bullish: bullish + upper wick <= MomentumWickPct%
bool IsMomentumBullish(double h, double l, double o, double c)
{
   if(!IsBullish(o, c)) return false;
   double cs = CandleSize(h, l);
   if(cs <= 0) return false;
   return UpperWick(h,o,c)/cs*100.0 <= MomentumWickPct;
}

// Momentum bearish: bearish + lower wick <= MomentumWickPct%
bool IsMomentumBearish(double h, double l, double o, double c)
{
   if(!IsBearish(o, c)) return false;
   double cs = CandleSize(h, l);
   if(cs <= 0) return false;
   return LowerWick(l,o,c)/cs*100.0 <= MomentumWickPct;
}

// Candle fully within range
bool IsWithinRange(double h, double l, double refH, double refL)
{
   return (h <= refH && l >= refL);
}

//+------------------------------------------------------------------+
//|  SMA DIRECTION                                                  |
//|  Returns 1 = price above SMA (buy only)                        |
//|         -1 = price below SMA (sell only)                       |
//|          0 = on SMA                                            |
//+------------------------------------------------------------------+
int GetSMADirection()
{
   double buf[1];
   if(CopyBuffer(hSMA, 0, 1, 1, buf) <= 0) return 0;
   double sma   = buf[0];
   double price = iClose(_Symbol, PERIOD_CURRENT, 1);
   if(price > sma) return  1;
   if(price < sma) return -1;
   return 0;
}

//+------------------------------------------------------------------+
//|  LOT SIZE                                                       |
//+------------------------------------------------------------------+
double CalculateLotSize(double entry, double sl)
{
   if(LotMode == FIXED_LOT) return FixedLot;
   double slDist = MathAbs(entry - sl);
   if(slDist <= 0) { Print("SL dist=0, fallback"); return FixedLot; }
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0 || tickValue <= 0) { Print("Tick error"); return FixedLot; }
   double valPerLot = tickValue / tickSize;
   double lot = RiskAmount / (slDist * valPerLot);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lot = MathFloor(lot / SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP)) * step;
   lot = MathMax(lot, SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN));
   lot = MathMin(lot, SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX));
   return lot;
}

//+------------------------------------------------------------------+
//|  IS TRADE OPEN BY THIS EA                                      |
//+------------------------------------------------------------------+
bool IsTradeOpen()
{
   for(int i = 0; i < PositionsTotal(); i++)
      if(PositionGetSymbol(i) == _Symbol)
         if((int)PositionGetInteger(POSITION_MAGIC) == MagicNumber)
            return true;
   return false;
}

//+------------------------------------------------------------------+
//|  RESET STATES                                                   |
//+------------------------------------------------------------------+
void ResetBuyState()
{
   buyState        = IDLE;
   buyC1High       = buyC1Low  = 0;
   buyC2High       = buyC2Low  = 0;
   buyC3Close      = 0;
   buySlLevel      = 0;
   buyRetestLevel  = 0;
   buyExpireLevel  = 0;
}

void ResetSellState()
{
   sellState       = IDLE;
   sellC1High      = sellC1Low = 0;
   sellC2High      = sellC2Low = 0;
   sellC3Close     = 0;
   sellSlLevel     = 0;
   sellRetestLevel = 0;
   sellExpireLevel = 0;
}

void ResetTradeState()
{
   inTrade    = false;
   bePlaced   = false;
   entryPrice = slPrice = tpPrice = bePrice = 0;
}

//+------------------------------------------------------------------+
//|  INIT                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(10);

   hSMA = iMA(_Symbol, PERIOD_CURRENT, SMA_Period, 0, MODE_SMA, PRICE_CLOSE);
   if(hSMA == INVALID_HANDLE)
   { Print("SMA handle error"); return INIT_FAILED; }

   ResetBuyState();
   ResetSellState();
   ResetTradeState();
   lastBarTime = 0;

   Print("Sandwich Pattern EA started | RR=", RR,
         " SMA=", SMA_Period,
         " DojiBody<=", DojiBodyPct, "%",
         " MomWick<=", MomentumWickPct, "%");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//|  ON TICK - runs every tick                                      |
//+------------------------------------------------------------------+
void OnTick()
{
   // --- Tick-level retest check (WAIT_RETEST state) ---
   // This must run every tick, not just on new bar
   if(!IsTradeOpen())
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

      // BUY retest watch
      if(buyState == WAIT_RETEST)
      {
         // Expire check: ask touches or exceeds upper bound
         if(ask >= buyExpireLevel)
         {
            Print("Buy setup EXPIRED: price ", ask, " >= upper bound ", buyExpireLevel);
            ResetBuyState();
         }
         // Entry check: bid touches doji high (retest from above)
         else if(bid <= buyRetestLevel)
         {
            double sl  = buySlLevel;
            double lot = CalculateLotSize(ask, sl);
            double risk = MathAbs(ask - sl);
            double tp  = ask + risk * RR;
            double be  = ask + risk * BE_RR;

            Print("BUY Retest Entry | Ask=", ask,
                  " SL=", sl, " TP=", tp, " Lot=", lot);

            if(trade.Buy(lot, _Symbol, 0, sl, tp, "BUY SANDWICH"))
            {
               Print("Buy placed OK");
               entryPrice = ask;
               slPrice    = sl;
               tpPrice    = tp;
               bePrice    = be;
               inTrade    = true;
               bePlaced   = false;
               ResetBuyState();
               ResetSellState();
            }
            else
               Print("Buy failed: ", trade.ResultRetcode(), " ",
                     trade.ResultRetcodeDescription());
         }
      }

      // SELL retest watch
      if(sellState == WAIT_RETEST)
      {
         // Expire check: bid touches or goes below lower bound
         if(bid <= sellExpireLevel)
         {
            Print("Sell setup EXPIRED: price ", bid, " <= lower bound ", sellExpireLevel);
            ResetSellState();
         }
         // Entry check: ask touches doji low (retest from below)
         else if(ask >= sellRetestLevel)
         {
            double sl  = sellSlLevel;
            double bid2 = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            double lot = CalculateLotSize(bid2, sl);
            double risk = MathAbs(bid2 - sl);
            double tp  = bid2 - risk * RR;
            double be  = bid2 - risk * BE_RR;

            Print("SELL Retest Entry | Bid=", bid2,
                  " SL=", sl, " TP=", tp, " Lot=", lot);

            if(trade.Sell(lot, _Symbol, 0, sl, tp, "SELL SANDWICH"))
            {
               Print("Sell placed OK");
               entryPrice = bid2;
               slPrice    = sl;
               tpPrice    = tp;
               bePrice    = be;
               inTrade    = true;
               bePlaced   = false;
               ResetSellState();
               ResetBuyState();
            }
            else
               Print("Sell failed: ", trade.ResultRetcode(), " ",
                     trade.ResultRetcodeDescription());
         }
      }
   }

   // --- Break Even (tick level) ---
   ProcessBreakEven();

   // --- Bar-close pattern scanning ---
   datetime barTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(barTime == lastBarTime) return;
   lastBarTime = barTime;

   double O = iOpen(_Symbol,  PERIOD_CURRENT, 1);
   double C = iClose(_Symbol, PERIOD_CURRENT, 1);
   double H = iHigh(_Symbol,  PERIOD_CURRENT, 1);
   double L = iLow(_Symbol,   PERIOD_CURRENT, 1);

   if(!IsTradeOpen())
      ProcessBarPattern(O, C, H, L);
}

//+------------------------------------------------------------------+
//|  BAR-CLOSE PATTERN PROCESSING                                   |
//+------------------------------------------------------------------+
void ProcessBarPattern(double O, double C, double H, double L)
{
   int smaDir = GetSMADirection();

   //================================================================
   // BUY PATTERN (only above SMA200)
   //================================================================
   if(smaDir >= 0) // price above or on SMA → buy allowed
   {
      if(buyState == IDLE)
      {
         if(IsValidC1Bullish(H, L, O, C))
         {
            buyState  = WAIT_C2;
            buyC1High = H; buyC1Low = L;
            Print("Buy C1 | H=", H, " L=", L);
         }
      }
      else if(buyState == WAIT_C2)
      {
         // Within C1 range → ignore
         if(IsWithinRange(H, L, buyC1High, buyC1Low))
         {
            // do nothing, keep waiting
         }
         // Doji outside C1 range → valid C2
         else if(IsValidDojiBullish(H, L, O, C))
         {
            // Extra check: doji must not break C1 range
            // (its high/low should be outside C1 to count as new candle)
            buyState  = WAIT_C3;
            buyC2High = H; buyC2Low = L;
            Print("Buy C2 Doji | H=", H, " L=", L);
         }
         else
         {
            // Not doji, outside C1 → reset, check if new C1
            ResetBuyState();
            if(IsValidC1Bullish(H, L, O, C))
            {
               buyState  = WAIT_C2;
               buyC1High = H; buyC1Low = L;
               Print("Buy C1 reset | H=", H, " L=", L);
            }
         }
      }
      else if(buyState == WAIT_C3)
      {
         // Doji high or low broken → setup invalid
         if(H > buyC2High || L < buyC2Low)
         {
            Print("Buy setup INVALID: doji H/L broken by H=", H, " L=", L);
            ResetBuyState();
            // Check if this candle can start fresh
            if(IsValidC1Bullish(H, L, O, C))
            {
               buyState  = WAIT_C2;
               buyC1High = H; buyC1Low = L;
               Print("Buy C1 fresh start | H=", H, " L=", L);
            }
         }
         // Within doji range → wait
         else if(IsWithinRange(H, L, buyC2High, buyC2Low))
         {
            // do nothing
         }
         // Outside doji range + momentum bullish + closes above doji high → C3 confirmed
         else if(IsMomentumBullish(H, L, O, C) && C > buyC2High)
         {
            buyC3Close     = C;
            buySlLevel     = buyC1Low;
            buyRetestLevel = buyC2High;                      // entry trigger
            double d       = MathAbs(C - buySlLevel);       // distance C3close to SL
            buyExpireLevel = C + d;                          // upper bound
            buyState       = WAIT_RETEST;
            Print("Buy C3 confirmed | C3close=", C,
                  " RetestAt=", buyRetestLevel,
                  " ExpireAt=", buyExpireLevel,
                  " SL=", buySlLevel);
         }
         else
         {
            // Outside doji but not valid C3 → reset
            Print("Buy: invalid C3, resetting");
            ResetBuyState();
            if(IsValidC1Bullish(H, L, O, C))
            {
               buyState  = WAIT_C2;
               buyC1High = H; buyC1Low = L;
            }
         }
      }
      // WAIT_RETEST is handled in OnTick (tick level)
   }
   else
   {
      // SMA says bearish → cancel any buy setup
      if(buyState != IDLE)
      {
         Print("Buy setup cancelled: price below SMA200");
         ResetBuyState();
      }
   }

   //================================================================
   // SELL PATTERN (only below SMA200)
   //================================================================
   if(smaDir <= 0) // price below or on SMA → sell allowed
   {
      if(sellState == IDLE)
      {
         if(IsValidC1Bearish(H, L, O, C))
         {
            sellState  = WAIT_C2;
            sellC1High = H; sellC1Low = L;
            Print("Sell C1 | H=", H, " L=", L);
         }
      }
      else if(sellState == WAIT_C2)
      {
         if(IsWithinRange(H, L, sellC1High, sellC1Low))
         {
            // do nothing
         }
         else if(IsValidDojiBearish(H, L, O, C))
         {
            sellState  = WAIT_C3;
            sellC2High = H; sellC2Low = L;
            Print("Sell C2 Doji | H=", H, " L=", L);
         }
         else
         {
            ResetSellState();
            if(IsValidC1Bearish(H, L, O, C))
            {
               sellState  = WAIT_C2;
               sellC1High = H; sellC1Low = L;
               Print("Sell C1 reset | H=", H, " L=", L);
            }
         }
      }
      else if(sellState == WAIT_C3)
      {
         // Doji high or low broken → invalid
         if(H > sellC2High || L < sellC2Low)
         {
            Print("Sell setup INVALID: doji H/L broken by H=", H, " L=", L);
            ResetSellState();
            if(IsValidC1Bearish(H, L, O, C))
            {
               sellState  = WAIT_C2;
               sellC1High = H; sellC1Low = L;
            }
         }
         else if(IsWithinRange(H, L, sellC2High, sellC2Low))
         {
            // do nothing
         }
         else if(IsMomentumBearish(H, L, O, C) && C < sellC2Low)
         {
            sellC3Close     = C;
            sellSlLevel     = sellC1High;
            sellRetestLevel = sellC2Low;                      // entry trigger
            double d        = MathAbs(C - sellSlLevel);      // distance C3close to SL
            sellExpireLevel = C - d;                          // lower bound
            sellState       = WAIT_RETEST;
            Print("Sell C3 confirmed | C3close=", C,
                  " RetestAt=", sellRetestLevel,
                  " ExpireAt=", sellExpireLevel,
                  " SL=", sellSlLevel);
         }
         else
         {
            Print("Sell: invalid C3, resetting");
            ResetSellState();
            if(IsValidC1Bearish(H, L, O, C))
            {
               sellState  = WAIT_C2;
               sellC1High = H; sellC1Low = L;
            }
         }
      }
   }
   else
   {
      // SMA says bullish → cancel any sell setup
      if(sellState != IDLE)
      {
         Print("Sell setup cancelled: price above SMA200");
         ResetSellState();
      }
   }
}

//+------------------------------------------------------------------+
//|  BREAK EVEN (tick level)                                        |
//+------------------------------------------------------------------+
void ProcessBreakEven()
{
   if(!UseBE || !inTrade || bePlaced) return;
   if(!IsTradeOpen()) { ResetTradeState(); return; }

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(PositionGetSymbol(i) != _Symbol) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      ulong  ticket = PositionGetInteger(POSITION_TICKET);
      ENUM_POSITION_TYPE type =
         (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      if(type == POSITION_TYPE_BUY && bid >= bePrice)
      {
         if(trade.PositionModify(ticket, entryPrice, tpPrice))
         { Print("BE set: SL → entry ", entryPrice); bePlaced = true; }
      }
      else if(type == POSITION_TYPE_SELL && ask <= bePrice)
      {
         if(trade.PositionModify(ticket, entryPrice, tpPrice))
         { Print("BE set: SL → entry ", entryPrice); bePlaced = true; }
      }
   }
}

//+------------------------------------------------------------------+
//|  DEINIT                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(hSMA);
   Print("Sandwich Pattern EA removed. Reason: ", reason);
}
//+------------------------------------------------------------------+
