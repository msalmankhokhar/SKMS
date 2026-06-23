//+------------------------------------------------------------------+
//|  Sandwich Pattern EA                                            |
//|  3-Candle Doji Pattern Strategy                                  |
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

input LOT_MODE LotMode              = FIXED_RISK; // Lot Mode
input double   FixedLot             = 0.05;       // Fixed Lot Size
input double   RiskAmount           = 50.0;       // Risk Amount (Account Currency)
input int      MagicNumber          = 12345;
input double   RR                   = 2.0;        // Risk:Reward Ratio
input bool     UseBE                = false;       // Break Even (ON/OFF)
input double   BE_RR                = 1.5;        // Break Even at RR
input double   DojiBodyPct          = 10.0;       // Doji: max body % of candle size
input double   MomentumWickPct      = 10;       // Momentum candle: max upper/lower wick %
input double   C1BodyMinPct         = 50.0;       // C1: min body % of candle size
input double   C1UpperWickMaxPct    = 30.0;       // C1: max upper wick % of candle size

CTrade trade;

//+------------------------------------------------------------------+
//|  PATTERN STATE                                                  |
//+------------------------------------------------------------------+
enum SETUP_STATE
{
   IDLE,           // no pattern being tracked
   WAIT_C2,        // C1 found, waiting for doji (C2)
   WAIT_ENTRY      // C2 found, waiting for entry candle
};

// Buy setup state
SETUP_STATE buyState;
double      buyC1High;
double      buyC1Low;
double      buyC1Open;
double      buyC1Close;
double      buyC2High;
double      buyC2Low;
double      buyC2Open;
double      buyC2Close;

// Sell setup state
SETUP_STATE sellState;
double      sellC1High;
double      sellC1Low;
double      sellC1Open;
double      sellC1Close;
double      sellC2High;
double      sellC2Low;
double      sellC2Open;
double      sellC2Close;

// Trade state for BE
bool        inTrade;
bool        bePlaced;
double      entryPrice;
double      slPrice;
double      tpPrice;
double      bePrice;
ENUM_POSITION_TYPE tradeType;

//--- Bar tracking
datetime    lastBarTime;

//+------------------------------------------------------------------+
//|  CANDLE CHECKS                                                  |
//+------------------------------------------------------------------+

// Is candle bullish
bool IsBullish(double o, double c) { return c > o; }

// Is candle bearish
bool IsBearish(double o, double c) { return c < o; }

// Candle size (full range)
double CandleSize(double h, double l) { return h - l; }

// Body size
double BodySize(double o, double c) { return MathAbs(c - o); }

// Upper wick
double UpperWick(double h, double o, double c) { return h - MathMax(o, c); }

// Lower wick
double LowerWick(double l, double o, double c) { return MathMin(o, c) - l; }

//--- C1: Normal bullish candle
//    body > C1BodyMinPct% of candle size
//    upper wick < C1UpperWickMaxPct% of candle size
bool IsValidC1Bullish(double h, double l, double o, double c)
{
   if(!IsBullish(o, c)) return false;
   double cs = CandleSize(h, l);
   if(cs <= 0) return false;
   double bodyPct  = BodySize(o, c)  / cs * 100.0;
   double uwPct    = UpperWick(h, o, c) / cs * 100.0;
   return bodyPct >= C1BodyMinPct && uwPct <= C1UpperWickMaxPct;
}

//--- C1: Normal bearish candle (mirror)
bool IsValidC1Bearish(double h, double l, double o, double c)
{
   if(!IsBearish(o, c)) return false;
   double cs = CandleSize(h, l);
   if(cs <= 0) return false;
   double bodyPct = BodySize(o, c)   / cs * 100.0;
   double lwPct   = LowerWick(l, o, c) / cs * 100.0;
   return bodyPct >= C1BodyMinPct && lwPct <= C1UpperWickMaxPct;
}

//--- Doji: body <= DojiBodyPct% of candle size, any of 3 types
//    Gravestone: upper wick dominant (lower wick small)
//    Dragonfly:  lower wick dominant (upper wick small)
//    Long-legged: both wicks significant
//    All 3 covered by just checking body <= DojiBodyPct%
bool IsValidDojiBullish(double h, double l, double o, double c)
{
   if(!IsBullish(o, c)) return false;
   double cs = CandleSize(h, l);
   if(cs <= 0) return false;
   double bodyPct = BodySize(o, c) / cs * 100.0;
   return bodyPct <= DojiBodyPct;
}

bool IsValidDojiBearish(double h, double l, double o, double c)
{
   if(!IsBearish(o, c)) return false;
   double cs = CandleSize(h, l);
   if(cs <= 0) return false;
   double bodyPct = BodySize(o, c) / cs * 100.0;
   return bodyPct <= DojiBodyPct;
}

//--- Momentum bullish: close > open, upper wick <= MomentumWickPct%
bool IsMomentumBullish(double h, double l, double o, double c)
{
   if(!IsBullish(o, c)) return false;
   double cs = CandleSize(h, l);
   if(cs <= 0) return false;
   double uwPct = UpperWick(h, o, c) / cs * 100.0;
   return uwPct <= MomentumWickPct;
}

//--- Momentum bearish: close < open, lower wick <= MomentumWickPct%
bool IsMomentumBearish(double h, double l, double o, double c)
{
   if(!IsBearish(o, c)) return false;
   double cs = CandleSize(h, l);
   if(cs <= 0) return false;
   double lwPct = LowerWick(l, o, c) / cs * 100.0;
   return lwPct <= MomentumWickPct;
}

//--- Candle within range (high <= refHigh AND low >= refLow)
bool IsWithinRange(double h, double l, double refHigh, double refLow)
{
   return (h <= refHigh && l >= refLow);
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
   if(tickSize <= 0 || tickValue <= 0) { Print("Tick error, fallback"); return FixedLot; }
   double valPerLot = tickValue / tickSize;
   double lot = RiskAmount / (slDist * valPerLot);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   lot = MathFloor(lot / step) * step;
   lot = MathMax(lot, minL);
   lot = MathMin(lot, maxL);
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
   buyState = IDLE;
   buyC1High = buyC1Low = buyC1Open = buyC1Close = 0;
   buyC2High = buyC2Low = buyC2Open = buyC2Close = 0;
}

void ResetSellState()
{
   sellState = IDLE;
   sellC1High = sellC1Low = sellC1Open = sellC1Close = 0;
   sellC2High = sellC2Low = sellC2Open = sellC2Close = 0;
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

   ResetBuyState();
   ResetSellState();
   ResetTradeState();

   lastBarTime = 0;

   Print("SKMS Doji EA started | RR=", RR,
         " DojiBody<=", DojiBodyPct, "%",
         " MomWick<=", MomentumWickPct, "%",
         " C1Body>=", C1BodyMinPct, "%",
         " C1UpWick<=", C1UpperWickMaxPct, "%");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//|  ON TICK                                                        |
//+------------------------------------------------------------------+
void OnTick()
{
   datetime barTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(barTime == lastBarTime) return;
   lastBarTime = barTime;

   // Process last closed bar
   double O = iOpen(_Symbol,  PERIOD_CURRENT, 1);
   double C = iClose(_Symbol, PERIOD_CURRENT, 1);
   double H = iHigh(_Symbol,  PERIOD_CURRENT, 1);
   double L = iLow(_Symbol,   PERIOD_CURRENT, 1);

   ProcessPattern(O, C, H, L);
   ProcessBreakEven();
}

//+------------------------------------------------------------------+
//|  PATTERN PROCESSING                                             |
//+------------------------------------------------------------------+
void ProcessPattern(double O, double C, double H, double L)
{
   if(IsTradeOpen()) return;

   //================================================================
   // BUY PATTERN
   //================================================================
   if(buyState == IDLE)
   {
      // Look for valid C1 bullish
      if(IsValidC1Bullish(H, L, O, C))
      {
         buyState  = WAIT_C2;
         buyC1High = H; buyC1Low = L;
         buyC1Open = O; buyC1Close = C;
         Print("Buy C1 found | H=", H, " L=", L, " O=", O, " C=", C);
      }
   }
   else if(buyState == WAIT_C2)
   {
      // If candle is within C1 range → ignore, keep waiting
      if(IsWithinRange(H, L, buyC1High, buyC1Low))
      {
         Print("Buy: candle within C1 range, ignoring");
      }
      // Candle outside C1 range → check if valid bullish doji
      else if(IsValidDojiBullish(H, L, O, C))
      {
         buyState  = WAIT_ENTRY;
         buyC2High = H; buyC2Low = L;
         buyC2Open = O; buyC2Close = C;
         Print("Buy C2 (Doji) found | H=", H, " L=", L, " O=", O, " C=", C);
      }
      else
      {
         // Not a doji and outside C1 range → check if this can be new C1
         // Reset and re-evaluate this candle as potential C1
         ResetBuyState();
         if(IsValidC1Bullish(H, L, O, C))
         {
            buyState  = WAIT_C2;
            buyC1High = H; buyC1Low = L;
            buyC1Open = O; buyC1Close = C;
            Print("Buy: C1 reset with new candle | H=", H, " L=", L);
         }
      }
   }
   else if(buyState == WAIT_ENTRY)
   {
      // If candle within C2 (doji) range → ignore, keep waiting
      if(IsWithinRange(H, L, buyC2High, buyC2Low))
      {
         Print("Buy: candle within C2 range, ignoring");
      }
      // Candle outside range → check entry conditions
      else
      {
         // Entry: bullish momentum candle closing above C2 high
         if(IsMomentumBullish(H, L, O, C) && C > buyC2High)
         {
            double sl  = buyC1Low;
            double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            double lot = CalculateLotSize(ask, sl);
            double risk = MathAbs(ask - sl);
            double tp  = ask + risk * RR;
            double be  = ask + risk * BE_RR;

            Print("BUY Entry | Ask=", ask, " SL=", sl,
                  " TP=", tp, " Lot=", lot);

            if(trade.Buy(lot, _Symbol, 0, sl, tp, "BUY DOJI"))
            {
               Print("Buy placed OK");
               entryPrice = ask;
               slPrice    = sl;
               tpPrice    = tp;
               bePrice    = be;
               inTrade    = true;
               bePlaced   = false;
               tradeType  = POSITION_TYPE_BUY;
               ResetBuyState();
               ResetSellState(); // cancel any sell setup
            }
            else
               Print("Buy failed: ", trade.ResultRetcode(), " ",
                     trade.ResultRetcodeDescription());
         }
         else
         {
            // Outside C2 range but not valid entry
            // Reset and check if this candle can start a new pattern
            ResetBuyState();
            if(IsValidC1Bullish(H, L, O, C))
            {
               buyState  = WAIT_C2;
               buyC1High = H; buyC1Low = L;
               buyC1Open = O; buyC1Close = C;
               Print("Buy: reset after failed entry, new C1 | H=", H, " L=", L);
            }
         }
      }
   }

   //================================================================
   // SELL PATTERN (mirror logic)
   //================================================================
   if(sellState == IDLE)
   {
      if(IsValidC1Bearish(H, L, O, C))
      {
         sellState  = WAIT_C2;
         sellC1High = H; sellC1Low = L;
         sellC1Open = O; sellC1Close = C;
         Print("Sell C1 found | H=", H, " L=", L, " O=", O, " C=", C);
      }
   }
   else if(sellState == WAIT_C2)
   {
      if(IsWithinRange(H, L, sellC1High, sellC1Low))
      {
         Print("Sell: candle within C1 range, ignoring");
      }
      else if(IsValidDojiBearish(H, L, O, C))
      {
         sellState  = WAIT_ENTRY;
         sellC2High = H; sellC2Low = L;
         sellC2Open = O; sellC2Close = C;
         Print("Sell C2 (Doji) found | H=", H, " L=", L, " O=", O, " C=", C);
      }
      else
      {
         ResetSellState();
         if(IsValidC1Bearish(H, L, O, C))
         {
            sellState  = WAIT_C2;
            sellC1High = H; sellC1Low = L;
            sellC1Open = O; sellC1Close = C;
            Print("Sell: C1 reset with new candle | H=", H, " L=", L);
         }
      }
   }
   else if(sellState == WAIT_ENTRY)
   {
      if(IsWithinRange(H, L, sellC2High, sellC2Low))
      {
         Print("Sell: candle within C2 range, ignoring");
      }
      else
      {
         // Entry: bearish momentum candle closing below C2 low
         if(IsMomentumBearish(H, L, O, C) && C < sellC2Low)
         {
            double sl  = sellC1High;
            double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            double lot = CalculateLotSize(bid, sl);
            double risk = MathAbs(bid - sl);
            double tp  = bid - risk * RR;
            double be  = bid - risk * BE_RR;

            Print("SELL Entry | Bid=", bid, " SL=", sl,
                  " TP=", tp, " Lot=", lot);

            if(trade.Sell(lot, _Symbol, 0, sl, tp, "SELL DOJI"))
            {
               Print("Sell placed OK");
               entryPrice = bid;
               slPrice    = sl;
               tpPrice    = tp;
               bePrice    = be;
               inTrade    = true;
               bePlaced   = false;
               tradeType  = POSITION_TYPE_SELL;
               ResetSellState();
               ResetBuyState(); // cancel any buy setup
            }
            else
               Print("Sell failed: ", trade.ResultRetcode(), " ",
                     trade.ResultRetcodeDescription());
         }
         else
         {
            ResetSellState();
            if(IsValidC1Bearish(H, L, O, C))
            {
               sellState  = WAIT_C2;
               sellC1High = H; sellC1Low = L;
               sellC1Open = O; sellC1Close = C;
               Print("Sell: reset after failed entry, new C1 | H=", H, " L=", L);
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//|  BREAK EVEN                                                     |
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

      ulong ticket = PositionGetInteger(POSITION_TICKET);
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
   Print("SKMS Doji EA removed. Reason: ", reason);
}
//+------------------------------------------------------------------+
