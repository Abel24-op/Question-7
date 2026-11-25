-- (a) Tables and seed data
CREATE TABLE customers (
    customer_id SERIAL PRIMARY KEY,
    full_name   TEXT NOT NULL
);

CREATE TABLE readings (
    reading_id       SERIAL PRIMARY KEY,
    customer_id      INTEGER NOT NULL REFERENCES customers(customer_id),
    reading_month    DATE NOT NULL CHECK (reading_month = DATE_TRUNC('month', reading_month)::DATE),
    previous_reading NUMERIC(10, 2) NOT NULL CHECK (previous_reading >= 0),
    current_reading  NUMERIC(10, 2) NOT NULL CHECK (current_reading >= 0),
    CONSTRAINT uq_readings_customer_month UNIQUE (customer_id, reading_month)
);

CREATE TABLE bills (
    bill_id     SERIAL PRIMARY KEY,
    reading_id  INTEGER NOT NULL UNIQUE REFERENCES readings(reading_id),
    charge      NUMERIC(10, 2) NOT NULL CHECK (charge >= 0),
    amount_paid NUMERIC(10, 2) NOT NULL DEFAULT 0.00 CHECK (amount_paid >= 0),
    due_on      DATE NOT NULL,
    CONSTRAINT chk_bills_paid_within_charge CHECK (amount_paid <= charge)
);

CREATE TABLE receivable_snapshot (
    snapshot_date DATE PRIMARY KEY,
    total_due     NUMERIC(12, 2) NOT NULL DEFAULT 0.00
);

-- (b) Function
CREATE OR REPLACE FUNCTION fn_water_charge(p_units NUMERIC)
RETURNS NUMERIC(10, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_tier1 NUMERIC(10, 2);
    v_tier2 NUMERIC(10, 2);
BEGIN
    IF p_units IS NULL OR p_units < 0 THEN
        RAISE EXCEPTION 'Consumption units cannot be NULL or negative, got %', p_units;
    END IF;

    IF p_units <= 10 THEN
        RETURN ROUND(p_units * 5.00, 2);
    ELSE
        v_tier1 := 10 * 5.00;
        v_tier2 := (p_units - 10) * 8.00;
        RETURN ROUND(v_tier1 + v_tier2, 2);
    END IF;
END;
$$;

-- (d) Trigger
CREATE OR REPLACE FUNCTION tf_readings_check_order()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.current_reading < NEW.previous_reading THEN
        RAISE EXCEPTION 'current_reading (%) cannot be less than previous_reading (%)',
            NEW.current_reading, NEW.previous_reading;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_readings_check_order
BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW
EXECUTE FUNCTION tf_readings_check_order();

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_generate_bill(p_reading_id INTEGER, p_due_on DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_prev   NUMERIC(10, 2);
    v_curr   NUMERIC(10, 2);
    v_units  NUMERIC(10, 2);
    v_charge NUMERIC(10, 2);
BEGIN
    SELECT previous_reading, current_reading
    INTO v_prev, v_curr
    FROM readings
    WHERE reading_id = p_reading_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown reading_id %', p_reading_id;
    END IF;

    IF EXISTS (SELECT 1 FROM bills WHERE reading_id = p_reading_id) THEN
        RAISE EXCEPTION 'Reading % already has a bill', p_reading_id;
    END IF;

    v_units  := v_curr - v_prev;
    v_charge := fn_water_charge(v_units);

    INSERT INTO bills (reading_id, charge, amount_paid, due_on)
    VALUES (p_reading_id, v_charge, 0.00, p_due_on);
END;
$$;

-- Seed 3 customers and 6 readings (zero, exactly 10, and above 10 units)
INSERT INTO customers (full_name) VALUES
    ('Chisomo Banda'),
    ('Mutinta Tembo'),
    ('Mwape Lungu');

INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading) VALUES
    (1, DATE '2026-09-01', 100.00, 100.00), -- 0 units
    (1, DATE '2026-10-01', 100.00, 110.00), -- 10 units
    (2, DATE '2026-09-01', 50.00,  65.00),  -- 15 units
    (2, DATE '2026-10-01', 65.00,  71.00),  -- 6 units
    (3, DATE '2026-09-01', 200.00, 212.50), -- 12.5 units
    (3, DATE '2026-10-01', 212.50, 212.50); -- 0 units

CALL pr_generate_bill(1, DATE '2026-10-15');
CALL pr_generate_bill(2, DATE '2026-11-15');
CALL pr_generate_bill(3, DATE '2026-10-20');
CALL pr_generate_bill(4, DATE '2026-11-20');
CALL pr_generate_bill(5, DATE '2026-10-25');
CALL pr_generate_bill(6, DATE '2026-11-25');

-- (e) View
CREATE OR REPLACE VIEW v_overdue_bills AS
SELECT
    c.full_name AS customer_name,
    b.due_on,
    (b.charge - b.amount_paid) AS outstanding_amount
FROM bills b
JOIN readings r ON r.reading_id = b.reading_id
JOIN customers c ON c.customer_id = r.customer_id
WHERE b.due_on < CURRENT_DATE
  AND b.amount_paid < b.charge;

-- (f) Index, query, and EXPLAIN
CREATE INDEX idx_bills_unpaid_due_on ON bills (due_on)
WHERE amount_paid < charge;

-- Justification: Filtering on due_on for unpaid bills (amount_paid < charge) is served
-- directly by a partial index on due_on, excluding settled bills.
EXPLAIN (ANALYZE, BUFFERS)
SELECT bill_id, reading_id, charge, amount_paid, due_on
FROM bills
WHERE amount_paid < charge
  AND due_on < CURRENT_DATE;

-- (g) Procedure and scheduled job
CREATE OR REPLACE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql
AS $$
DECLARE
    v_total NUMERIC(12, 2);
BEGIN
    SELECT COALESCE(SUM(charge - amount_paid), 0.00)
    INTO v_total
    FROM bills
    WHERE amount_paid < charge;

    INSERT INTO receivable_snapshot (snapshot_date, total_due)
    VALUES (CURRENT_DATE, v_total)
    ON CONFLICT (snapshot_date) DO UPDATE
    SET total_due = EXCLUDED.total_due;
END;
$$;

-- pg_cron daily at 00:30
SELECT cron.schedule(
    'q7_refresh_receivables',
    '30 0 * * *',
    $$CALL pr_refresh_receivables();$$
);