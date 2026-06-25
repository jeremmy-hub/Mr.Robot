//+------------------------------------------------------------------+
//|               Mustafa_FX_retest_strategy.mq5                     |
//+------------------------------------------------------------------+
#property copyright "Mustafa_FX"
#property link      ""
#property version   "4.01"
#property description "Mustafa_FX Retest Strategy - Bias Aligned (hardened build)"

#include <Trade\Trade.mqh>

//--- Main Trade Inputs
input double   RiskPercent           = 1.0;       // Total Risk per trade (%)
input double   TP1_RewardRatio       = 1.0;       // Position 1 TP (R-Multiple)
input double   TP2_RewardRatio       = 1.5;       // Position 2 TP (R-Multiple)
input double   BE_Activation_Percent = 50.0;      // Move SL to Entry when price reaches this % of TP1
input ulong    BaseMagicNumber       = 123456;    // Base Magic Number
input int      MaxSetupsPerTimeframe = 1;         // Max concurrent setups PER timeframe
input bool     CancelOnBiasFlip      = true;      // Cancel pending orders if Master Bias flips

//--- Master Bias & Trend Inputs
input int      BiasEmaLen            = 200;       // Master Trend Bias EMA
input int      FastEmaLen            = 34;        // Fast Trend EMA
input int      SlowEmaLen            = 144;       // Slow Trend EMA
input int      PullEmaLen            = 21;        // Pullback Target EMA

//--- Breakout & Execution Inputs
input int      AtrLen                = 14;        // ATR Length
input int      BreakLookback         = 20;        // Breakout Swing Lookback
input double   MinBreakBodyAtr       = 0.20;      // Min Breakout Body / ATR
input double   EntryDepthAtr         = 0.40;      // Entry Depth into pullback (ATR)
input double   SlBufferAtr           = 0.30;      // Stop Loss buffer beyond swing (ATR)
input int      MaxHuntBars           = 40;        // Max bars before limit order expires

//--- Global Objects & Handles
CTrade         trade;
datetime       lastBarTime;
int            biasEmaHandle, fastEmaHandle, slowEmaHandle, pullEmaHandle, atrHandle;

//--- Timeframe-Aware Magic Numbers
ulong          Magic_TP1, Magic_TP2;

//--- Cached symbol constraints (refreshed each new bar)
double         g_volStep, g_minVol, g_maxVol, g_tickSize, g_stopsLevel;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    // Generate Unique Magic Numbers based on the timeframe
    Magic_TP1 = BaseMagicNumber + PeriodSeconds(_Period);
    Magic_TP2 = Magic_TP1 + 1;

    // Initialize Indicators
    biasEmaHandle = iMA(_Symbol, _Period, BiasEmaLen, 0, MODE_EMA, PRICE_CLOSE);
    fastEmaHandle = iMA(_Symbol, _Period, FastEmaLen, 0, MODE_EMA, PRICE_CLOSE);
    slowEmaHandle = iMA(_Symbol, _Period, SlowEmaLen, 0, MODE_EMA, PRICE_CLOSE);
    pullEmaHandle = iMA(_Symbol, _Period, PullEmaLen, 0, MODE_EMA, PRICE_CLOSE);
    atrHandle     = iATR(_Symbol, _Period, AtrLen);

    if(biasEmaHandle == INVALID_HANDLE || fastEmaHandle == INVALID_HANDLE ||
       slowEmaHandle == INVALID_HANDLE || pullEmaHandle == INVALID_HANDLE || atrHandle == INVALID_HANDLE)
    {
        Print("Error initializing indicator handles!");
        return(INIT_FAILED);
    }

    Print("Mustafa_FX_retest_strategy v4.01 Initialized Successfully.");
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    IndicatorRelease(biasEmaHandle);
    IndicatorRelease(fastEmaHandle);
    IndicatorRelease(slowEmaHandle);
    IndicatorRelease(pullEmaHandle);
    IndicatorRelease(atrHandle);
}

//+------------------------------------------------------------------+
//| Helpers: price / volume normalization                            |
//+------------------------------------------------------------------+
double NormalizePrice(double price)
{
    double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    if(tickSize <= 0) return NormalizeDouble(price, _Digits);
    return NormalizeDouble(MathRound(price / tickSize) * tickSize, _Digits);
}

double NormalizeVolumeDown(double vol)
{
    double step = g_volStep;
    if(step <= 0) step = g_minVol;
    if(step <= 0) return 0;
    vol = MathFloor(vol / step) * step;
    if(g_maxVol > 0 && vol > g_maxVol) vol = g_maxVol;
    return vol;
}

void RefreshSymbolConstraints()
{
    g_volStep    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    g_minVol     = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    g_maxVol     = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    g_tickSize   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    g_stopsLevel = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
}

//+------------------------------------------------------------------+
//| Resolve a broker-supported pending-order expiration mode         |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_TIME ResolveExpiration(datetime &expiration)
{
    long expMode = SymbolInfoInteger(_Symbol, SYMBOL_EXPIRATION_MODE);
    if((expMode & SYMBOL_EXPIRATION_SPECIFIED) != 0)
    {
        expiration = TimeCurrent() + (MaxHuntBars * PeriodSeconds(_Period));
        return ORDER_TIME_SPECIFIED;
    }
    // Fallback for accounts that don't accept a specified expiry on pendings
    expiration = 0;
    return ORDER_TIME_GTC;
}

//+------------------------------------------------------------------+
//| Calculate Lot Size                                               |
//+------------------------------------------------------------------+
double CalculateLotSize(double entryPrice, double slPrice)
{
    double riskAmount = AccountInfoDouble(ACCOUNT_BALANCE) * (RiskPercent / 100.0);
    double tickSize   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    double tickValue  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double slDistance = MathAbs(entryPrice - slPrice);

    // Guard against zero/invalid symbol data (FIX: no division by zero)
    if(slDistance <= 0 || tickSize <= 0 || tickValue <= 0) return 0;

    double lossInTicks = slDistance / tickSize;
    if(lossInTicks <= 0) return 0;

    return riskAmount / (lossInTicks * tickValue);
}

//+------------------------------------------------------------------+
//| Count active setups for this timeframe (FIX: ceiling, not floor) |
//+------------------------------------------------------------------+
int CountActiveSetups()
{
    int legs = 0;

    for(int i = 0; i < PositionsTotal(); i++)
    {
        if(PositionGetTicket(i) == 0) continue;
        if(PositionGetString(POSITION_SYMBOL) == _Symbol)
        {
            ulong m = PositionGetInteger(POSITION_MAGIC);
            if(m == Magic_TP1 || m == Magic_TP2) legs++;
        }
    }
    for(int i = 0; i < OrdersTotal(); i++)
    {
        if(OrderGetTicket(i) == 0) continue;
        if(OrderGetString(ORDER_SYMBOL) == _Symbol)
        {
            ulong m = OrderGetInteger(ORDER_MAGIC);
            if(m == Magic_TP1 || m == Magic_TP2) legs++;
        }
    }

    // Ceiling: a lone surviving leg (e.g. TP2 still open after TP1 hit)
    // must still count as one active setup, otherwise the gate re-opens.
    return (legs + 1) / 2;
}

//+------------------------------------------------------------------+
//| Cancel stale pending orders when Master Bias flips               |
//+------------------------------------------------------------------+
void ManagePendingOrders(bool bullBias, bool bearBias)
{
    if(!CancelOnBiasFlip) return;

    for(int i = OrdersTotal() - 1; i >= 0; i--)
    {
        ulong ticket = OrderGetTicket(i);
        if(ticket == 0) continue;
        if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;

        ulong m = OrderGetInteger(ORDER_MAGIC);
        if(m != Magic_TP1 && m != Magic_TP2) continue;

        long type = OrderGetInteger(ORDER_TYPE);
        bool isBuyPending  = (type == ORDER_TYPE_BUY_LIMIT  || type == ORDER_TYPE_BUY_STOP);
        bool isSellPending = (type == ORDER_TYPE_SELL_LIMIT || type == ORDER_TYPE_SELL_STOP);

        if((isBuyPending && bearBias) || (isSellPending && bullBias))
        {
            if(!trade.OrderDelete(ticket))
                PrintFormat("Failed to cancel stale pending #%I64u, retcode=%u", ticket, trade.ResultRetcode());
        }
    }
}

//+------------------------------------------------------------------+
//| Manage Break-Even Logic (Runs every tick)                        |
//+------------------------------------------------------------------+
void ManageBreakEven()
{
    double minStopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;

    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(ticket == 0) continue;
        ulong m = PositionGetInteger(POSITION_MAGIC);

        // Ensure the trade belongs to this specific timeframe's EA
        if(PositionGetString(POSITION_SYMBOL) == _Symbol && (m == Magic_TP1 || m == Magic_TP2))
        {
            double entry = PositionGetDouble(POSITION_PRICE_OPEN);
            double sl    = PositionGetDouble(POSITION_SL);
            double tp    = PositionGetDouble(POSITION_TP);
            long   type  = PositionGetInteger(POSITION_TYPE);

            if(tp == 0) continue;

            double fullTpDistance = MathAbs(tp - entry);
            if(fullTpDistance == 0) continue;

            // Normalize the activation distance based on TP1
            double targetDistance = fullTpDistance;
            if(m == Magic_TP2 && TP2_RewardRatio > 0)
                targetDistance = (fullTpDistance / TP2_RewardRatio) * TP1_RewardRatio;

            double activationDist = targetDistance * (BE_Activation_Percent / 100.0);

            if(type == POSITION_TYPE_BUY)
            {
                double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
                if(currentBid >= (entry + activationDist) && sl < entry)
                {
                    if(entry - currentBid < -minStopLevel) // Broker compliance check
                    {
                        if(!trade.PositionModify(ticket, NormalizePrice(entry), tp))
                            PrintFormat("BE modify failed #%I64u, retcode=%u", ticket, trade.ResultRetcode());
                    }
                }
            }
            else if(type == POSITION_TYPE_SELL)
            {
                double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
                if(currentAsk <= (entry - activationDist) && (sl > entry || sl == 0))
                {
                    if(currentAsk - entry < -minStopLevel) // Broker compliance check
                    {
                        if(!trade.PositionModify(ticket, NormalizePrice(entry), tp))
                            PrintFormat("BE modify failed #%I64u, retcode=%u", ticket, trade.ResultRetcode());
                    }
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Validate a pending BUY setup against broker constraints          |
//+------------------------------------------------------------------+
bool ValidateBuySetup(double limitPrice, double slPrice, double tp1, double tp2)
{
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

    if(slPrice >= limitPrice) { Print("Skip BUY: SL not below entry."); return false; }
    if(tp1 <= limitPrice || tp2 <= limitPrice) { Print("Skip BUY: TP not above entry."); return false; }
    if(limitPrice >= ask - g_stopsLevel) { Print("Skip BUY: limit too close to / above market."); return false; }
    if((limitPrice - slPrice) < g_stopsLevel) { Print("Skip BUY: SL inside stops level."); return false; }
    if((tp1 - limitPrice) < g_stopsLevel) { Print("Skip BUY: TP1 inside stops level."); return false; }
    return true;
}

//+------------------------------------------------------------------+
//| Validate a pending SELL setup against broker constraints         |
//+------------------------------------------------------------------+
bool ValidateSellSetup(double limitPrice, double slPrice, double tp1, double tp2)
{
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

    if(slPrice <= limitPrice) { Print("Skip SELL: SL not above entry."); return false; }
    if(tp1 >= limitPrice || tp2 >= limitPrice) { Print("Skip SELL: TP not below entry."); return false; }
    if(limitPrice <= bid + g_stopsLevel) { Print("Skip SELL: limit too close to / below market."); return false; }
    if((slPrice - limitPrice) < g_stopsLevel) { Print("Skip SELL: SL inside stops level."); return false; }
    if((limitPrice - tp1) < g_stopsLevel) { Print("Skip SELL: TP1 inside stops level."); return false; }
    return true;
}

//+------------------------------------------------------------------+
//| Place a two-leg setup; rolls back leg 1 if leg 2 fails           |
//+------------------------------------------------------------------+
bool PlaceTwoLegSetup(bool isBuy, double legLot, double price, double sl,
                      double tp1, double tp2)
{
    datetime expiration;
    ENUM_ORDER_TYPE_TIME timeType = ResolveExpiration(expiration);

    // Leg 1 (TP1)
    trade.SetExpertMagicNumber(Magic_TP1);
    bool ok1;
    if(isBuy) ok1 = trade.BuyLimit (legLot, price, _Symbol, sl, tp1, timeType, expiration, "Mustafa_FX 1");
    else      ok1 = trade.SellLimit(legLot, price, _Symbol, sl, tp1, timeType, expiration, "Mustafa_FX 1");

    bool   placed1 = ok1 && (trade.ResultRetcode() == TRADE_RETCODE_DONE ||
                             trade.ResultRetcode() == TRADE_RETCODE_PLACED);
    ulong  ticket1 = trade.ResultOrder();

    if(!placed1)
    {
        PrintFormat("Leg 1 placement failed, retcode=%u", trade.ResultRetcode());
        return false;
    }

    // Leg 2 (TP2)
    trade.SetExpertMagicNumber(Magic_TP2);
    bool ok2;
    if(isBuy) ok2 = trade.BuyLimit (legLot, price, _Symbol, sl, tp2, timeType, expiration, "Mustafa_FX 2");
    else      ok2 = trade.SellLimit(legLot, price, _Symbol, sl, tp2, timeType, expiration, "Mustafa_FX 2");

    bool placed2 = ok2 && (trade.ResultRetcode() == TRADE_RETCODE_DONE ||
                           trade.ResultRetcode() == TRADE_RETCODE_PLACED);

    if(!placed2)
    {
        PrintFormat("Leg 2 placement failed, retcode=%u. Rolling back leg 1 #%I64u.",
                    trade.ResultRetcode(), ticket1);
        if(!trade.OrderDelete(ticket1))
            PrintFormat("Rollback delete failed #%I64u, retcode=%u", ticket1, trade.ResultRetcode());
        return false;
    }

    return true;
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    // BE management must run on every tick
    ManageBreakEven();

    // --- New-bar gate (FIX: consume the bar immediately, run body once/bar) ---
    datetime currentBarTime = (datetime)SeriesInfoInteger(_Symbol, _Period, SERIES_LASTBAR_DATE);
    if(currentBarTime == lastBarTime) return;
    lastBarTime = currentBarTime;

    RefreshSymbolConstraints();
    if(g_minVol <= 0) return;

    // =========================================================================
    // DATA ACQUISITION (FIX: validate every copy before use)
    // =========================================================================
    double biasEma[], fEma[], sEma[], pEma[], atrArr[];
    ArraySetAsSeries(biasEma, true); ArraySetAsSeries(fEma, true);
    ArraySetAsSeries(sEma, true);    ArraySetAsSeries(pEma, true);
    ArraySetAsSeries(atrArr, true);

    if(CopyBuffer(biasEmaHandle, 0, 1, 1, biasEma) < 1) return;
    if(CopyBuffer(fastEmaHandle, 0, 1, 2, fEma)    < 2) return;
    if(CopyBuffer(slowEmaHandle, 0, 1, 1, sEma)    < 1) return;
    if(CopyBuffer(pullEmaHandle, 0, 1, 1, pEma)    < 1) return;
    if(CopyBuffer(atrHandle,     0, 1, 1, atrArr)  < 1) return;
    if(atrArr[0] <= 0) return;

    double high[], low[], close[], open[];
    ArraySetAsSeries(high, true);  ArraySetAsSeries(low, true);
    ArraySetAsSeries(close, true); ArraySetAsSeries(open, true);

    if(CopyHigh (_Symbol, _Period, 1, BreakLookback + 1, high) < BreakLookback + 1) return;
    if(CopyLow  (_Symbol, _Period, 1, BreakLookback + 1, low)  < BreakLookback + 1) return;
    if(CopyClose(_Symbol, _Period, 1, 2, close) < 2) return;
    if(CopyOpen (_Symbol, _Period, 1, 2, open)  < 2) return;

    // =========================================================================
    // BIAS-ALIGNED RETEST STRATEGY
    // =========================================================================
    double body = MathAbs(close[0] - open[0]);
    bool breakBodyOk = body >= (atrArr[0] * MinBreakBodyAtr);

    // --- BIAS & TREND CONDITIONS ---
    bool bullBias  = (close[0] > biasEma[0]);
    bool bullTrend = bullBias && (fEma[0] > sEma[0]) && (fEma[0] > fEma[1]);

    bool bearBias  = (close[0] < biasEma[0]);
    bool bearTrend = bearBias && (fEma[0] < sEma[0]) && (fEma[0] < fEma[1]);

    // --- Cancel stale pendings if bias flipped (frees up the setup slot) ---
    ManagePendingOrders(bullBias, bearBias);

    // --- Setup-count gate (FIX: ceiling count) ---
    if(CountActiveSetups() >= MaxSetupsPerTimeframe) return;

    // --- SWING LEVELS ---
    double hiBefore = high[1]; double loBefore = low[1];
    for(int i = 1; i <= BreakLookback; i++)
    {
        if(high[i] > hiBefore) hiBefore = high[i];
        if(low[i]  < loBefore) loBefore = low[i];
    }

    // --- BREAKOUT CONDITIONS ---
    bool bullBreakout = bullTrend && (close[0] > hiBefore) && (close[0] > open[0]) && breakBodyOk;
    bool bearBreakout = bearTrend && (close[0] < loBefore) && (close[0] < open[0]) && breakBodyOk;

    // =========================================================================
    // EXECUTION
    // =========================================================================
    if(bullBreakout)
    {
        double limitPrice = NormalizePrice(pEma[0] - (EntryDepthAtr * atrArr[0]));
        double slPrice    = NormalizePrice(loBefore - (SlBufferAtr * atrArr[0]));
        double slDistance = MathAbs(limitPrice - slPrice);
        double tp1Price   = NormalizePrice(limitPrice + (slDistance * TP1_RewardRatio));
        double tp2Price   = NormalizePrice(limitPrice + (slDistance * TP2_RewardRatio));

        if(!ValidateBuySetup(limitPrice, slPrice, tp1Price, tp2Price)) return;

        double totalLotSize = CalculateLotSize(limitPrice, slPrice);
        double legLot = NormalizeVolumeDown(totalLotSize / 2.0);  // FIX: both legs normalized & equal
        if(legLot < g_minVol)
        {
            Print("BUY skipped: per-leg lot below minimum at current risk.");
            return;
        }

        PlaceTwoLegSetup(true, legLot, limitPrice, slPrice, tp1Price, tp2Price);
        return;
    }

    if(bearBreakout)
    {
        double limitPrice = NormalizePrice(pEma[0] + (EntryDepthAtr * atrArr[0]));
        double slPrice    = NormalizePrice(hiBefore + (SlBufferAtr * atrArr[0]));
        double slDistance = MathAbs(slPrice - limitPrice);
        double tp1Price   = NormalizePrice(limitPrice - (slDistance * TP1_RewardRatio));
        double tp2Price   = NormalizePrice(limitPrice - (slDistance * TP2_RewardRatio));

        if(!ValidateSellSetup(limitPrice, slPrice, tp1Price, tp2Price)) return;

        double totalLotSize = CalculateLotSize(limitPrice, slPrice);
        double legLot = NormalizeVolumeDown(totalLotSize / 2.0);  // FIX: both legs normalized & equal
        if(legLot < g_minVol)
        {
            Print("SELL skipped: per-leg lot below minimum at current risk.");
            return;
        }

        PlaceTwoLegSetup(false, legLot, limitPrice, slPrice, tp1Price, tp2Price);
        return;
    }
}
