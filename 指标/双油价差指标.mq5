//+------------------------------------------------------------------+
//|                                              SpreadIndicator.mq5 |
//|                                    Copyright 2024, Your Name     |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, Your Name"
#property version   "1.00"
#property description "计算两个手动输入品种的收盘价差，显示在独立子窗口"

// --- 指标在独立子窗口显示，使用1个缓冲区，绘制1条线 ---
#property indicator_separate_window
#property indicator_buffers 1
#property indicator_plots   1

// --- 定义曲线的绘制属性 ---
#property indicator_label1  "Spread"
#property indicator_type1   DRAW_LINE
#property indicator_color1  clrDodgerBlue
#property indicator_style1  STYLE_SOLID
#property indicator_width1  2

// --- 输入参数（两个标的手动输入）---
input string Symbol1 = "XBRUSD.s";   // 第一个品种
input string Symbol2 = "XTIUSD.s";   // 第二个品种

// --- 指标缓冲区 ---
double spreadBuffer[];               // 价差数组

//+------------------------------------------------------------------+
//| 自定义指标初始化                                                 |
//+------------------------------------------------------------------+
int OnInit()
{
   // 验证两个交易品种是否存在
   bool isCustom1, isCustom2;
   if(!SymbolExist(Symbol1, isCustom1) || !SymbolExist(Symbol2, isCustom2))
   {
      Print("错误: 交易品种 ", Symbol1, " 或 ", Symbol2, " 不存在");
      return INIT_PARAMETERS_INCORRECT;
   }

   // 关联缓冲区并设为时间序列（索引0为最新值）
   SetIndexBuffer(0, spreadBuffer, INDICATOR_DATA);
   ArraySetAsSeries(spreadBuffer, true);

   // 设置空值标记（价格无效时曲线不连线）
   PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, EMPTY_VALUE);

   // 设置指标简称
   string shortname = StringFormat("Spread(%s-%s)", Symbol1, Symbol2);
   IndicatorSetString(INDICATOR_SHORTNAME, shortname);

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| 自定义指标迭代（核心计算逻辑）                                   |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
{
   // 设置时间数组为时间序列（方便时间对齐，但实际未使用）
   ArraySetAsSeries(time, true);

   // 确定计算起始位置：全量或增量
   int start = prev_calculated == 0 ? 0 : prev_calculated - 1;

   // 循环计算价差
   for(int i = start; i < rates_total; i++)
   {
      // 分别获取两个品种在当前索引（时间点）的收盘价
      double price1 = iClose(Symbol1, _Period, i);
      double price2 = iClose(Symbol2, _Period, i);

      // 若任一价格无效，则设为空值
      if(price1 == 0 || price2 == 0)
         spreadBuffer[i] = EMPTY_VALUE;
      else
         spreadBuffer[i] = price1 - price2;   // 简单价差（可根据需要修改）
   }

   return rates_total;
}
//+------------------------------------------------------------------+