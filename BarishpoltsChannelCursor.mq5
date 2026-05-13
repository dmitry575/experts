//+------------------------------------------------------------------+
//|                                     BarishpoltsChannelCursor.mq5 |
//|                                        Copyright 2026, Tarakanov |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Tarakanov"
#property version   "1.00"
#property description "Trades reversals at the borders of a parallel channel"
#property description "built on the last three confirmed price extremums."
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>

//================================================================
//                       Input parameters
//================================================================
input group "=== General ==="
input long   InpMagicNumber                 = 20260507; // Magic number
input bool   InpDebugMode                   = true;     // Verbose debug logging

input group "=== Extremums and channel ==="
input int    InpExtremumDepth               = 5;        // Bars left/right for fractal
input int    InpMaxExtremumsToScan          = 1000;     // Max bars to scan
input int    InpMinChannelWidthPoints       = 50;       // Min channel width (points)
input int    InpChannelTouchTolerancePoints = 10;       // Touch tolerance (points)
input bool   InpDrawChannel                 = true;     // Draw channel on chart

input group "=== Risk management ==="
input int    InpMinStopLossPoints           = 100;      // Minimum SL in points
input double InpRiskPercent                 = 2.0;      // Risk per trade (%)
input bool   InpUseTakeProfit               = true;     // Use TP at opposite border
input int    InpSlippagePoints              = 20;       // Slippage in points

input group "=== Trade frequency ==="
input int    InpMaxTradesBeforePause        = 3;        // Trades before pause
input int    InpPauseHours                  = 24;       // Pause duration (hours)

//================================================================
//                       Types
//================================================================
enum ENUM_EXT_TYPE
  {
   EXT_HIGH = 1,
   EXT_LOW  = -1
  };

struct ExtremumPoint
  {
   datetime         time;
   double           price;
   ENUM_EXT_TYPE    type;
  };

struct ChannelInfo
  {
   bool             ready;
   datetime         base_time;     // reference time (= ext[0].time)
   double           main_base;     // price of "main" line at base_time
   double           parallel_base; // price of "parallel" line at base_time
   double           slope;         // price-units per second
   bool             upper_is_main; // true if main line is the UPPER border
   double           width;         // |main - parallel|, constant
  };

//================================================================
//                       Globals
//================================================================
CTrade        g_trade;
CPositionInfo g_pos;
CSymbolInfo   g_sym;

ExtremumPoint g_ext[3];          // last three alternating extremums
ChannelInfo   g_channel;
datetime      g_last_trade_bar = 0; // bar time of the last EA-opened trade
datetime      g_last_scan_bar  = 0; // bar time of the last extremum scan

const string  PREFIX_OBJ = "BARI_";

//+------------------------------------------------------------------+
//| Initialization                                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints((ulong)InpSlippagePoints);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_trade.SetMarginMode();

   if(!g_sym.Name(_Symbol))
     {
      Print("[BARI] Failed to attach symbol info");
      return(INIT_FAILED);
     }

   if(InpExtremumDepth < 1)
     { Print("[BARI] InpExtremumDepth must be >= 1"); return(INIT_FAILED); }
   if(InpRiskPercent <= 0.0 || InpRiskPercent > 100.0)
     { Print("[BARI] InpRiskPercent must be in (0, 100]"); return(INIT_FAILED); }
   if(InpMinStopLossPoints < 1)
     { Print("[BARI] InpMinStopLossPoints invalid"); return(INIT_FAILED); }

   g_channel.ready = false;
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Deinitialization                                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   ObjectsDeleteAll(0, PREFIX_OBJ);
  }

//+------------------------------------------------------------------+
//| Tick handler                                                     |
//+------------------------------------------------------------------+
void OnTick()
  {
   if(!g_sym.RefreshRates())
      return;

   datetime cur_bar = iTime(_Symbol, _Period, 0);
   if(cur_bar == 0) return;

   // Re-scan extremums and rebuild channel only on a new bar.
   if(cur_bar != g_last_scan_bar)
     {
      UpdateExtremumsAndChannel();
      g_last_scan_bar = cur_bar;
      if(InpDrawChannel && g_channel.ready) DrawChannel();
     }

   if(!g_channel.ready)             return;
   if(IsPaused())                   return;
   if(HasOpenPosition())            return;
   if(cur_bar == g_last_trade_bar)  return;   // no re-entry on same bar

   CheckSignalAndTrade(cur_bar);
  }

//================================================================
//                Extremum detection
//================================================================
//+------------------------------------------------------------------+
//| Scan history, collect alternating extremums, take last 3.        |
//| Returns true on successful scan (channel may still be not ready).|
//+------------------------------------------------------------------+
bool UpdateExtremumsAndChannel()
  {
   int bars = Bars(_Symbol, _Period);
   if(bars < InpExtremumDepth * 2 + 5) return(false);

   int scan = MathMin(InpMaxExtremumsToScan, bars - InpExtremumDepth - 2);
   if(scan < InpExtremumDepth * 2 + 1) return(false);

   double   high[];
   double   low[];
   datetime tm[];
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low,  true);
   ArraySetAsSeries(tm,   true);

   int copy_n = scan + InpExtremumDepth + 2;
   if(CopyHigh(_Symbol, _Period, 0, copy_n, high) <= 0) return(false);
   if(CopyLow (_Symbol, _Period, 0, copy_n, low ) <= 0) return(false);
   if(CopyTime(_Symbol, _Period, 0, copy_n, tm  ) <= 0) return(false);

   // Collect alternating extremums from oldest to newest.
   ExtremumPoint coll[];
   ArrayResize(coll, 0);

   // Series shift: 0 = newest, larger = older.
   // We require closed bars on BOTH sides of the candidate, so the
   // most recent allowed shift is InpExtremumDepth + 1 (avoids using
   // the unfinished bar 0 in fractal validation).
   int i_old = MathMin(scan, copy_n - InpExtremumDepth - 1);
   int i_new = InpExtremumDepth + 1;

   for(int i = i_old; i >= i_new; i--)
     {
      bool is_high = true;
      bool is_low  = true;

      for(int j = 1; j <= InpExtremumDepth; j++)
        {
         if(is_high && (high[i] <= high[i + j] || high[i] <= high[i - j]))
            is_high = false;
         if(is_low  && (low[i]  >= low[i + j]  || low[i]  >= low[i - j]))
            is_low = false;
         if(!is_high && !is_low) break;
        }

      // Skip ambiguous (both/none) cases.
      if(is_high == is_low) continue;

      ENUM_EXT_TYPE typ = is_high ? EXT_HIGH : EXT_LOW;
      double price      = is_high ? high[i] : low[i];

      AddExtremum(coll, tm[i], price, typ);
     }

   int total = ArraySize(coll);
   if(total < 3)
     {
      g_channel.ready = false;
      return(true);
     }

   for(int k = 0; k < 3; k++)
      g_ext[k] = coll[total - 3 + k];

   // After dedup, neighbours alternate type, so [0] and [2] must be
   // the same type and [1] is the opposite.
   if(g_ext[0].type != g_ext[2].type || g_ext[1].type == g_ext[0].type)
     {
      g_channel.ready = false;
      return(true);
     }

   BuildChannelFromExtremums();
   return(true);
  }

//+------------------------------------------------------------------+
//| Append an extremum to the chronological list, deduplicating      |
//| consecutive same-type ones (keep the more extreme).              |
//+------------------------------------------------------------------+
void AddExtremum(ExtremumPoint &arr[], datetime t, double p, ENUM_EXT_TYPE typ)
  {
   int sz = ArraySize(arr);
   if(sz == 0)
     {
      ArrayResize(arr, 1);
      arr[0].time  = t;
      arr[0].price = p;
      arr[0].type  = typ;
      return;
     }

   if(arr[sz - 1].type == typ)
     {
      bool replace = (typ == EXT_HIGH) ? (p > arr[sz - 1].price)
                                       : (p < arr[sz - 1].price);
      if(replace)
        {
         arr[sz - 1].time  = t;
         arr[sz - 1].price = p;
        }
     }
   else
     {
      ArrayResize(arr, sz + 1);
      arr[sz].time  = t;
      arr[sz].price = p;
      arr[sz].type  = typ;
     }
  }

//================================================================
//                Channel construction
//================================================================
//+------------------------------------------------------------------+
//| Build channel from g_ext[0..2]. Encodes both lines as            |
//| price = base + slope * (t - base_time) to avoid precision loss.  |
//+------------------------------------------------------------------+
void BuildChannelFromExtremums()
  {
   long dt = (long)g_ext[2].time - (long)g_ext[0].time;
   if(dt <= 0)
     {
      g_channel.ready = false;
      return;
     }

   g_channel.base_time = g_ext[0].time;
   g_channel.slope     = (g_ext[2].price - g_ext[0].price) / (double)dt;
   g_channel.main_base = g_ext[0].price;

   // Parallel line passes through (g_ext[1].time, g_ext[1].price).
   // Re-express it at base_time with the same slope.
   double dt1 = (double)((long)g_channel.base_time - (long)g_ext[1].time);
   g_channel.parallel_base = g_ext[1].price + g_channel.slope * dt1;

   g_channel.upper_is_main = (g_ext[0].type == EXT_HIGH);
   g_channel.width         = MathAbs(g_channel.main_base - g_channel.parallel_base);
   g_channel.ready         = (g_channel.width >= InpMinChannelWidthPoints * _Point);

   if(InpDebugMode && g_channel.ready)
     {
      static datetime last_log = 0;
      if(g_ext[2].time != last_log)
        {
         last_log = g_ext[2].time;
         PrintFormat("[BARI] Channel: %s/%s/%s width=%.5f slope=%G",
                     EnumToString(g_ext[0].type),
                     EnumToString(g_ext[1].type),
                     EnumToString(g_ext[2].type),
                     g_channel.width, g_channel.slope);
        }
     }
  }

//================================================================
//                Channel boundary prices
//================================================================
double LinePriceMain(datetime t)
  {
   double dt = (double)((long)t - (long)g_channel.base_time);
   return(g_channel.main_base + g_channel.slope * dt);
  }

double LinePriceParallel(datetime t)
  {
   double dt = (double)((long)t - (long)g_channel.base_time);
   return(g_channel.parallel_base + g_channel.slope * dt);
  }

double UpperBoundary(datetime t)
  { return(g_channel.upper_is_main ? LinePriceMain(t) : LinePriceParallel(t)); }

double LowerBoundary(datetime t)
  { return(g_channel.upper_is_main ? LinePriceParallel(t) : LinePriceMain(t)); }

//================================================================
//                Trade signal & execution
//================================================================
//+------------------------------------------------------------------+
//| Check whether current Bid/Ask touches a channel boundary.        |
//+------------------------------------------------------------------+
void CheckSignalAndTrade(datetime cur_bar)
  {
   datetime now   = TimeCurrent();
   double   upper = UpperBoundary(now);
   double   lower = LowerBoundary(now);
   double   width = upper - lower;

   if(width < InpMinChannelWidthPoints * _Point) return;

   double tol = InpChannelTouchTolerancePoints * _Point;
   double bid = g_sym.Bid();
   double ask = g_sym.Ask();

   // Touch upper border -> SELL (back into the channel)
   if(bid >= upper - tol && bid <= upper + tol)
     {
      OpenTrade(ORDER_TYPE_SELL, upper, lower, cur_bar);
      return;
     }

   // Touch lower border -> BUY (back into the channel)
   if(ask <= lower + tol && ask >= lower - tol)
     {
      OpenTrade(ORDER_TYPE_BUY, upper, lower, cur_bar);
      return;
     }
  }

//+------------------------------------------------------------------+
//| Build SL/TP, compute risk-based lot, send order via CTrade.      |
//+------------------------------------------------------------------+
void OpenTrade(ENUM_ORDER_TYPE type, double upper, double lower, datetime cur_bar)
  {
   double width_pts = (upper - lower) / _Point;

   // SL must be >= MinStopLossPoints AND <= channel width.
   // If channel is narrower than min SL, the spec is unsatisfiable.
   if(width_pts < InpMinStopLossPoints)
     {
      if(InpDebugMode)
         PrintFormat("[BARI] width %.0f pts < min SL %d, skip",
                     width_pts, InpMinStopLossPoints);
      return;
     }

   // Default: use full channel width as SL distance (max allowed).
   double sl_pts = width_pts;
   if(sl_pts < InpMinStopLossPoints) sl_pts = InpMinStopLossPoints;

   long   min_stops = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double min_dist  = min_stops * _Point;

   double price, sl, tp = 0.0;
   if(type == ORDER_TYPE_BUY)
     {
      price = g_sym.Ask();
      sl    = price - sl_pts * _Point;
      if(InpUseTakeProfit) tp = upper;
     }
   else
     {
      price = g_sym.Bid();
      sl    = price + sl_pts * _Point;
      if(InpUseTakeProfit) tp = lower;
     }

   // Respect broker's STOPS_LEVEL.
   if(min_dist > 0.0)
     {
      if(type == ORDER_TYPE_BUY)
        {
         if(price - sl < min_dist) sl = price - min_dist;
         if(tp > 0.0 && tp - price < min_dist) tp = 0.0;
        }
      else
        {
         if(sl - price < min_dist) sl = price + min_dist;
         if(tp > 0.0 && price - tp < min_dist) tp = 0.0;
        }
     }

   price = NormalizeDouble(price, _Digits);
   sl    = NormalizeDouble(sl,    _Digits);
   tp    = (tp > 0.0) ? NormalizeDouble(tp, _Digits) : 0.0;

   double real_sl_pts = MathAbs(price - sl) / _Point;
   double lot = CalculateLotSize(real_sl_pts);
   if(lot <= 0.0)
     {
      if(InpDebugMode)
         PrintFormat("[BARI] lot=0 (sl_pts=%.1f balance=%.2f)",
                     real_sl_pts, AccountInfoDouble(ACCOUNT_BALANCE));
      return;
     }

   bool ok = (type == ORDER_TYPE_BUY)
             ? g_trade.Buy (lot, _Symbol, price, sl, tp, "Barishpolts")
             : g_trade.Sell(lot, _Symbol, price, sl, tp, "Barishpolts");

   if(ok)
     {
      g_last_trade_bar = cur_bar;
      if(InpDebugMode)
         PrintFormat("[BARI] %s lot=%.2f @ %.5f SL=%.5f TP=%.5f",
                     (type == ORDER_TYPE_BUY ? "BUY" : "SELL"),
                     lot, price, sl, tp);
     }
   else if(InpDebugMode)
     {
      PrintFormat("[BARI] order failed: %u %s",
                  g_trade.ResultRetcode(),
                  g_trade.ResultRetcodeDescription());
     }
  }

//================================================================
//                Lot size by risk %
//================================================================
//+------------------------------------------------------------------+
//| Lot = RiskMoney / (SL_distance_points * point_value_per_lot).    |
//| point_value_per_lot = TICK_VALUE * (Point / TICK_SIZE), in       |
//| account currency.                                                |
//+------------------------------------------------------------------+
double CalculateLotSize(double sl_pts)
  {
   if(sl_pts <= 0.0) return(0.0);

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(balance <= 0.0) return(0.0);

   double risk_money = balance * InpRiskPercent / 100.0;

   double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick_value <= 0.0 || tick_size <= 0.0) return(0.0);

   double point_value = tick_value * (_Point / tick_size);
   if(point_value <= 0.0) return(0.0);

   double loss_per_lot = sl_pts * point_value;
   if(loss_per_lot <= 0.0) return(0.0);

   double lot = risk_money / loss_per_lot;

   double v_min  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double v_max  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double v_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(v_step <= 0.0) v_step = 0.01;

   // Floor to volume step (under-risking is safer than over-risking).
   lot = MathFloor(lot / v_step) * v_step;
   if(lot < v_min) return(0.0);
   if(lot > v_max) lot = v_max;

   // Normalize to digits implied by volume step.
   int digits = 0;
   double s = v_step;
   while(s < 1.0 && digits < 8) { s *= 10.0; digits++; }
   lot = NormalizeDouble(lot, digits);
   return(lot);
  }

//================================================================
//                Position presence (symbol + magic)
//================================================================
bool HasOpenPosition()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(g_pos.SelectByIndex(i))
        {
         if(g_pos.Symbol() == _Symbol && g_pos.Magic() == InpMagicNumber)
            return(true);
        }
     }
   return(false);
  }

//================================================================
//                Pause: max N entries per PauseHours window
//================================================================
//+------------------------------------------------------------------+
//| Count IN-deals (entries) executed by us during the last N hours. |
//+------------------------------------------------------------------+
int CountOurEntriesInLastHours(int hours)
  {
   datetime from = TimeCurrent() - hours * 3600;
   if(!HistorySelect(from, TimeCurrent() + 60))
      return(0);

   int total = HistoryDealsTotal();
   int count = 0;
   for(int i = 0; i < total; i++)
     {
      ulong tk = HistoryDealGetTicket(i);
      if(tk == 0) continue;

      string sym = HistoryDealGetString (tk, DEAL_SYMBOL);
      long   mg  = HistoryDealGetInteger(tk, DEAL_MAGIC);
      long   ent = HistoryDealGetInteger(tk, DEAL_ENTRY);

      if(sym == _Symbol && mg == InpMagicNumber && ent == DEAL_ENTRY_IN)
         count++;
     }
   return(count);
  }

bool IsPaused()
  {
   int n = CountOurEntriesInLastHours(InpPauseHours);
   if(n >= InpMaxTradesBeforePause)
     {
      static datetime last_msg = 0;
      if(InpDebugMode && TimeCurrent() - last_msg >= 3600)
        {
         PrintFormat("[BARI] paused: %d entries in last %d h", n, InpPauseHours);
         last_msg = TimeCurrent();
        }
      return(true);
     }
   return(false);
  }

//================================================================
//                Channel visualization
//================================================================
void DrawChannel()
  {
   datetime t1   = g_ext[0].time;
   datetime tnow = TimeCurrent();

   string n_main = PREFIX_OBJ + "main";
   string n_par  = PREFIX_OBJ + "par";

   double m1 = LinePriceMain(t1);
   double m2 = LinePriceMain(tnow);
   double p1 = LinePriceParallel(t1);
   double p2 = LinePriceParallel(tnow);

   if(ObjectFind(0, n_main) < 0)
      ObjectCreate(0, n_main, OBJ_TREND, 0, t1, m1, tnow, m2);
   else
     {
      ObjectMove(0, n_main, 0, t1,   m1);
      ObjectMove(0, n_main, 1, tnow, m2);
     }
   ObjectSetInteger(0, n_main, OBJPROP_COLOR,     clrYellow);
   ObjectSetInteger(0, n_main, OBJPROP_RAY_RIGHT, true);
   ObjectSetInteger(0, n_main, OBJPROP_WIDTH,     1);

   if(ObjectFind(0, n_par) < 0)
      ObjectCreate(0, n_par, OBJ_TREND, 0, t1, p1, tnow, p2);
   else
     {
      ObjectMove(0, n_par, 0, t1,   p1);
      ObjectMove(0, n_par, 1, tnow, p2);
     }
   ObjectSetInteger(0, n_par, OBJPROP_COLOR,     clrAqua);
   ObjectSetInteger(0, n_par, OBJPROP_RAY_RIGHT, true);
   ObjectSetInteger(0, n_par, OBJPROP_WIDTH,     1);
  }
//+------------------------------------------------------------------+
