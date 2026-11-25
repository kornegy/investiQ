# Forecast Methodology Disclosure

* InvestiQ does **not** predict prices. It shows **scenario ranges** and **statistical model outputs**
  derived from historical data, with their assumptions and limitations.
* Models: naive random walk (baseline), random walk with drift, geometric Brownian motion Monte Carlo,
  block-bootstrap Monte Carlo. No language model is used for forecasting.
* Scenarios (optimistic/base/pessimistic) correspond to the 80th/50th/20th percentiles of historical
  returns over periods of the same length. **No probability is assigned to a scenario.**
* Every model is evaluated by walk-forward validation against a naive baseline (MAE, RMSE, MASE,
  directional accuracy, interval coverage). If a model does not outperform the baseline, the app says so
  and does not present the output as a useful signal.
* All forecasts you create are recorded before the target date and later compared with actual outcomes
  on the Forecast Accuracy page, including unsuccessful ones.
* Limitations: markets change regimes; history may be short, adjusted or incomplete; free data excludes
  delisted companies (survivorship bias); extreme events are under-represented; model intervals can be
  too narrow.
* Full formulas: `docs/FINANCIAL_METHODOLOGY.md` §8.
