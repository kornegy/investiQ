import Foundation

/// Migrations of the user database (docs/DATABASE_SCHEMA.md §1).
public enum UserSchema {
    public static let migrations: [Migration] = [v1]

    static let ageCategories = "'under18','from18to25','from26to35','from36to50','from51to65','over65'"
    static let transactionTypes = "'buy','sell','dividend','coupon','interest','fee','tax','deposit','withdrawal','split','fxConversion','bondRedemption'"

    static let v1 = Migration(version: 1, name: "initial user schema", sql: """
    CREATE TABLE user_profile (
        singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
        id TEXT NOT NULL,
        display_name TEXT NOT NULL CHECK (length(display_name) BETWEEN 1 AND 100),
        created_at TEXT NOT NULL,
        age_category TEXT CHECK (age_category IS NULL OR age_category IN (\(ageCategories))),
        educational_mode INTEGER NOT NULL CHECK (educational_mode IN (0, 1))
    );

    CREATE TABLE user_preferences (key TEXT PRIMARY KEY, value TEXT NOT NULL);

    CREATE TABLE financial_profile (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        country TEXT NOT NULL CHECK (length(country) = 2),
        primary_currency TEXT NOT NULL CHECK (length(primary_currency) = 3),
        age_category TEXT NOT NULL CHECK (age_category IN (\(ageCategories))),
        knowledge_level TEXT NOT NULL CHECK (knowledge_level IN ('beginner','intermediate','advanced')),
        goals TEXT NOT NULL,
        horizon TEXT NOT NULL CHECK (horizon IN ('underOneYear','oneToThreeYears','threeToTenYears','overTenYears')),
        income_stability TEXT NOT NULL CHECK (income_stability IN ('stable','variable','irregular','noIncome')),
        essential_monthly_expenses TEXT,
        emergency_fund TEXT NOT NULL CHECK (emergency_fund IN ('none','underThreeMonths','threeToSixMonths','overSixMonths')),
        debt_status TEXT NOT NULL CHECK (debt_status IN ('none','lowInterestOnly','highInterest','difficultyRepaying')),
        risk_attitude TEXT NOT NULL CHECK (risk_attitude IN ('avoidLosses','cautious','balanced','acceptsLargeSwings')),
        experience TEXT NOT NULL CHECK (experience IN ('none','savingsOnly','fundsOrETFs','stocksOrBonds','extensive')),
        updated_at TEXT NOT NULL
    );

    CREATE TABLE exchanges (
        mic TEXT PRIMARY KEY CHECK (length(mic) = 4),
        name TEXT NOT NULL,
        country TEXT NOT NULL,
        time_zone TEXT NOT NULL
    );

    CREATE TABLE instruments (
        id TEXT PRIMARY KEY,
        kind TEXT NOT NULL CHECK (kind IN ('stock','etf','governmentBond','corporateBond')),
        name TEXT NOT NULL CHECK (length(name) BETWEEN 1 AND 300),
        isin TEXT UNIQUE CHECK (isin IS NULL OR length(isin) = 12),
        figi TEXT,
        country TEXT,
        sector TEXT,
        issuer TEXT,
        currency TEXT NOT NULL CHECK (length(currency) = 3),
        source TEXT NOT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
    );

    CREATE TABLE listings (
        id TEXT PRIMARY KEY,
        instrument_id TEXT NOT NULL REFERENCES instruments(id) ON DELETE CASCADE,
        mic TEXT REFERENCES exchanges(mic),
        ticker TEXT NOT NULL CHECK (length(ticker) BETWEEN 1 AND 24),
        trading_currency TEXT NOT NULL CHECK (length(trading_currency) = 3),
        is_primary INTEGER NOT NULL DEFAULT 0 CHECK (is_primary IN (0, 1)),
        UNIQUE (mic, ticker)
    );
    CREATE INDEX idx_listings_instrument ON listings(instrument_id);

    CREATE TABLE stock_details (
        instrument_id TEXT PRIMARY KEY REFERENCES instruments(id) ON DELETE CASCADE,
        payload TEXT NOT NULL
    );

    CREATE TABLE bond_details (
        instrument_id TEXT PRIMARY KEY REFERENCES instruments(id) ON DELETE CASCADE,
        issuer_type TEXT NOT NULL CHECK (issuer_type IN ('government','corporate','supranational','municipal')),
        face_value TEXT NOT NULL,
        coupon_rate TEXT NOT NULL,
        coupon_frequency INTEGER NOT NULL CHECK (coupon_frequency IN (0, 1, 2, 4, 12)),
        day_count TEXT NOT NULL CHECK (day_count IN ('thirty360US','thirtyE360','actual360','actual365Fixed','actualActualICMA')),
        issue_date TEXT,
        first_coupon_date TEXT,
        maturity_date TEXT NOT NULL,
        call_schedule TEXT NOT NULL DEFAULT '[]',
        credit_rating TEXT,
        rating_agency TEXT,
        rating_date TEXT,
        min_denomination TEXT,
        seniority TEXT,
        CHECK (issue_date IS NULL OR maturity_date > issue_date)
    );

    CREATE TABLE etf_details (
        instrument_id TEXT PRIMARY KEY REFERENCES instruments(id) ON DELETE CASCADE,
        payload TEXT NOT NULL
    );

    CREATE TABLE portfolios (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL CHECK (length(name) BETWEEN 1 AND 100),
        kind TEXT NOT NULL CHECK (kind IN ('real','virtual')),
        base_currency TEXT NOT NULL CHECK (length(base_currency) = 3),
        created_at TEXT NOT NULL,
        archived INTEGER NOT NULL DEFAULT 0 CHECK (archived IN (0, 1)),
        notes TEXT,
        UNIQUE (name, kind)
    );

    CREATE TABLE transactions (
        id TEXT PRIMARY KEY,
        portfolio_id TEXT NOT NULL REFERENCES portfolios(id) ON DELETE CASCADE,
        type TEXT NOT NULL CHECK (type IN (\(transactionTypes))),
        instrument_id TEXT REFERENCES instruments(id) ON DELETE RESTRICT,
        listing_id TEXT REFERENCES listings(id) ON DELETE SET NULL,
        trade_date TEXT NOT NULL CHECK (length(trade_date) = 10),
        settle_date TEXT,
        quantity TEXT,
        price TEXT,
        amount TEXT,
        currency TEXT NOT NULL CHECK (length(currency) = 3),
        fees TEXT NOT NULL DEFAULT '0',
        fee_currency TEXT,
        tax_withheld TEXT NOT NULL DEFAULT '0',
        accrued_interest TEXT,
        fx_rate_to_base TEXT,
        counter_currency TEXT,
        counter_amount TEXT,
        split_numerator INTEGER,
        split_denominator INTEGER,
        notes TEXT CHECK (notes IS NULL OR length(notes) <= 2000),
        source TEXT NOT NULL CHECK (source IN ('manual','csvImport','simulator','demo')),
        external_ref TEXT,
        created_at TEXT NOT NULL,
        UNIQUE (portfolio_id, external_ref),
        CHECK (type NOT IN ('buy','sell','bondRedemption') OR (instrument_id IS NOT NULL AND quantity IS NOT NULL AND price IS NOT NULL)),
        CHECK (type NOT IN ('dividend','coupon') OR (instrument_id IS NOT NULL AND amount IS NOT NULL)),
        CHECK (type NOT IN ('interest','fee','tax','deposit','withdrawal') OR amount IS NOT NULL),
        CHECK (type <> 'split' OR (instrument_id IS NOT NULL AND split_numerator > 0 AND split_denominator > 0)),
        CHECK (type <> 'fxConversion' OR (amount IS NOT NULL AND counter_amount IS NOT NULL AND counter_currency IS NOT NULL AND counter_currency <> currency))
    );
    CREATE INDEX idx_transactions_portfolio_date ON transactions(portfolio_id, trade_date);
    CREATE INDEX idx_transactions_instrument ON transactions(instrument_id);

    -- Simulator transactions may only exist in virtual portfolios (real and virtual data never mix).
    CREATE TRIGGER transactions_simulator_virtual_only BEFORE INSERT ON transactions
    WHEN NEW.source = 'simulator' AND (SELECT kind FROM portfolios WHERE id = NEW.portfolio_id) <> 'virtual'
    BEGIN SELECT RAISE(ABORT, 'simulator transactions require a virtual portfolio'); END;

    CREATE TABLE portfolio_snapshots (
        id TEXT PRIMARY KEY,
        portfolio_id TEXT NOT NULL REFERENCES portfolios(id) ON DELETE CASCADE,
        as_of TEXT NOT NULL,
        market_value TEXT,
        cash TEXT,
        net_invested TEXT,
        currency TEXT NOT NULL,
        ledger_hash TEXT NOT NULL,
        price_source TEXT,
        computed_at TEXT NOT NULL,
        UNIQUE (portfolio_id, as_of)
    );

    CREATE TABLE simulator_sessions (
        portfolio_id TEXT PRIMARY KEY REFERENCES portfolios(id) ON DELETE CASCADE,
        mode TEXT NOT NULL CHECK (mode IN ('live','historical')),
        start_date TEXT NOT NULL,
        sim_date TEXT NOT NULL,
        starting_capital TEXT NOT NULL,
        currency TEXT NOT NULL,
        fee_model TEXT NOT NULL,
        benchmark_instrument_id TEXT REFERENCES instruments(id) ON DELETE SET NULL,
        CHECK (sim_date >= start_date)
    );
    CREATE TRIGGER simulator_sessions_virtual_only BEFORE INSERT ON simulator_sessions
    WHEN (SELECT kind FROM portfolios WHERE id = NEW.portfolio_id) <> 'virtual'
    BEGIN SELECT RAISE(ABORT, 'simulator sessions require a virtual portfolio'); END;

    CREATE TABLE watchlists (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL UNIQUE CHECK (length(name) BETWEEN 1 AND 100),
        created_at TEXT NOT NULL
    );
    CREATE TABLE watchlist_items (
        watchlist_id TEXT NOT NULL REFERENCES watchlists(id) ON DELETE CASCADE,
        instrument_id TEXT NOT NULL REFERENCES instruments(id) ON DELETE CASCADE,
        added_at TEXT NOT NULL,
        position INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (watchlist_id, instrument_id)
    );

    CREATE TABLE notification_rules (
        id TEXT PRIMARY KEY,
        kind TEXT NOT NULL CHECK (kind IN ('priceMove','earningsReport','economicEvent','dividendPayment','couponPayment','bondMaturity','riskChange','staleData','providerOutage')),
        instrument_id TEXT REFERENCES instruments(id) ON DELETE CASCADE,
        portfolio_id TEXT REFERENCES portfolios(id) ON DELETE CASCADE,
        threshold TEXT,
        enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1)),
        created_at TEXT NOT NULL,
        last_triggered_at TEXT
    );

    CREATE TABLE risk_assessments (
        id TEXT PRIMARY KEY,
        portfolio_id TEXT NOT NULL REFERENCES portfolios(id) ON DELETE CASCADE,
        computed_at TEXT NOT NULL,
        method_version TEXT NOT NULL,
        payload TEXT NOT NULL
    );
    CREATE INDEX idx_risk_assessments_portfolio ON risk_assessments(portfolio_id, computed_at);

    CREATE TABLE forecasts (
        id TEXT PRIMARY KEY,
        instrument_id TEXT NOT NULL REFERENCES instruments(id) ON DELETE RESTRICT,
        listing_key TEXT NOT NULL,
        model_id TEXT NOT NULL,
        model_version TEXT NOT NULL,
        created_at TEXT NOT NULL,
        origin_date TEXT NOT NULL,
        target_date TEXT NOT NULL,
        horizon_days INTEGER NOT NULL CHECK (horizon_days > 0),
        last_observation_date TEXT NOT NULL,
        origin_value REAL NOT NULL,
        point REAL NOT NULL,
        lower80 REAL NOT NULL, upper80 REAL NOT NULL,
        lower95 REAL NOT NULL, upper95 REAL NOT NULL,
        input_hash TEXT NOT NULL,
        data_source TEXT NOT NULL,
        validation_mase REAL,
        stale_input INTEGER NOT NULL DEFAULT 0 CHECK (stale_input IN (0, 1)),
        CHECK (last_observation_date <= origin_date),
        CHECK (target_date > origin_date),
        CHECK (lower95 <= lower80 AND lower80 <= upper80 AND upper80 <= upper95)
    );
    CREATE INDEX idx_forecasts_target ON forecasts(target_date);
    -- The forecast ledger is append-only: forecasts cannot be rewritten or hidden after the fact.
    CREATE TRIGGER forecasts_no_update BEFORE UPDATE ON forecasts
    BEGIN SELECT RAISE(ABORT, 'forecasts are append-only'); END;
    CREATE TRIGGER forecasts_no_delete BEFORE DELETE ON forecasts
    BEGIN SELECT RAISE(ABORT, 'forecasts are append-only'); END;

    CREATE TABLE forecast_evaluations (
        forecast_id TEXT PRIMARY KEY REFERENCES forecasts(id),
        evaluated_at TEXT NOT NULL,
        actual REAL NOT NULL,
        abs_error REAL NOT NULL,
        naive_abs_error REAL NOT NULL,
        in80 INTEGER NOT NULL CHECK (in80 IN (0, 1)),
        in95 INTEGER NOT NULL CHECK (in95 IN (0, 1)),
        direction_correct INTEGER CHECK (direction_correct IS NULL OR direction_correct IN (0, 1))
    );

    CREATE TABLE learning_progress (
        lesson_id TEXT PRIMARY KEY,
        status TEXT NOT NULL CHECK (status IN ('notStarted','inProgress','completed')),
        quiz_best_score INTEGER,
        quiz_attempts INTEGER NOT NULL DEFAULT 0,
        updated_at TEXT NOT NULL
    );

    CREATE TABLE planner_budget (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        monthly_income TEXT,
        essential_expenses TEXT,
        additional_expenses TEXT,
        debt_payments TEXT,
        emergency_fund TEXT,
        available_savings TEXT,
        currency TEXT NOT NULL,
        updated_at TEXT NOT NULL
    );
    CREATE TABLE planner_goals (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL CHECK (length(name) BETWEEN 1 AND 100),
        term TEXT NOT NULL CHECK (term IN ('short','long')),
        target_amount TEXT NOT NULL,
        currency TEXT NOT NULL,
        target_date TEXT,
        created_at TEXT NOT NULL
    );

    INSERT INTO exchanges (mic, name, country, time_zone) VALUES
        ('XPRA', 'Prague Stock Exchange', 'CZ', 'Europe/Prague'),
        ('XETR', 'Xetra', 'DE', 'Europe/Berlin'),
        ('XFRA', 'Frankfurt Stock Exchange', 'DE', 'Europe/Berlin'),
        ('XLON', 'London Stock Exchange', 'GB', 'Europe/London'),
        ('XAMS', 'Euronext Amsterdam', 'NL', 'Europe/Amsterdam'),
        ('XPAR', 'Euronext Paris', 'FR', 'Europe/Paris'),
        ('XBRU', 'Euronext Brussels', 'BE', 'Europe/Brussels'),
        ('XMIL', 'Euronext Milan', 'IT', 'Europe/Rome'),
        ('XMAD', 'Bolsa de Madrid', 'ES', 'Europe/Madrid'),
        ('XSWX', 'SIX Swiss Exchange', 'CH', 'Europe/Zurich'),
        ('XWBO', 'Wiener Börse', 'AT', 'Europe/Vienna'),
        ('XWAR', 'Warsaw Stock Exchange', 'PL', 'Europe/Warsaw'),
        ('XBUD', 'Budapest Stock Exchange', 'HU', 'Europe/Budapest'),
        ('XNYS', 'New York Stock Exchange', 'US', 'America/New_York'),
        ('XNAS', 'Nasdaq', 'US', 'America/New_York'),
        ('ARCX', 'NYSE Arca', 'US', 'America/New_York');
    """)
}
