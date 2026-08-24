-- ============================================================
-- create_dwh.sql
-- Data Warehouse - Star Schema (Oracle)
--
-- Run order: operational DB -> load CSVs -> this file
--            -> ETL_Process\initial_loading\
-- ============================================================

-- ############################################################
--                        DIMENSIONS
-- ############################################################

-- ============================================================
-- DATE DIMENSION  (surrogate key from date_dim_seq: 1, 2, 3, ...;
-- no OLTP source, so no back-reference. date_key 0 = Unknown member.)
-- ============================================================
CREATE TABLE date_dim (
    date_key          NUMBER(8)     NOT NULL,
    cal_date          DATE          NOT NULL,
    full_desc         VARCHAR2(40),
    day_week          VARCHAR2(10),
    day_num_month     NUMBER(2),
    last_day_ind      CHAR(1),
    cal_week_end_date DATE,
    cal_week_year     VARCHAR2(8),
    cal_month_name    VARCHAR2(10),
    cal_month_year    VARCHAR2(8),
    cal_year_month    NUMBER(6),
    cal_quarter       NUMBER(1),
    cal_year_quarter  VARCHAR2(7),
    cal_year          NUMBER(4),
    holiday_ind       CHAR(1) DEFAULT 'N',
    holiday_name      VARCHAR2(80),
    weekday_ind       CHAR(1),
    CONSTRAINT pk_date_dim PRIMARY KEY (date_key)
);

-- ============================================================
-- BRANCH DIMENSION  (SCD Type 2)
-- ============================================================
CREATE TABLE branch_dim (
    branch_key           NUMBER(10)     NOT NULL,             -- surrogate key
    br_ID                NUMBER(10)     NOT NULL,             -- natural key (OLTP name kept)
    br_name              VARCHAR2(100)  NOT NULL,
    br_city              VARCHAR2(50)   NOT NULL,
    br_state             VARCHAR2(50)   NOT NULL,
    br_email             VARCHAR2(100)  NOT NULL,
    effective_start_date DATE           NOT NULL,
    effective_end_date   DATE           DEFAULT DATE '9999-12-31' NOT NULL,
    is_current_flag      CHAR(1)        DEFAULT 'Y' NOT NULL,
    CONSTRAINT pk_branch_dim PRIMARY KEY (branch_key),
    CONSTRAINT fk_branchdim_oltp FOREIGN KEY (br_ID) REFERENCES branch (br_ID),
    CONSTRAINT chk_branch_dim_flag CHECK (is_current_flag IN ('Y','N'))
);

-- ============================================================
-- STAFF DIMENSION  (SCD Type 2)
-- The staff member's branch is NOT stored here: facts resolve
-- branch_key from the OLTP row (orders.br_ID, reservation.br_ID,
-- staff.br_ID for salary_payment) at load time.
-- ============================================================
CREATE TABLE staff_dim (
    staff_key            NUMBER(10)     NOT NULL,
    st_ID                NUMBER(10)     NOT NULL,             -- natural key
    st_name              VARCHAR2(120)  NOT NULL,             -- first + last combined
    st_email             VARCHAR2(100)  NOT NULL,
    st_position          VARCHAR2(50)   NOT NULL,             -- the single job-title column
    st_status            VARCHAR2(20)   NOT NULL,
    effective_start_date DATE           NOT NULL,
    effective_end_date   DATE           DEFAULT DATE '9999-12-31' NOT NULL,
    is_current_flag      CHAR(1)        DEFAULT 'Y' NOT NULL,
    CONSTRAINT pk_staff_dim PRIMARY KEY (staff_key),
    CONSTRAINT fk_staffdim_oltp FOREIGN KEY (st_ID) REFERENCES staff (st_ID),
    CONSTRAINT chk_staff_dim_flag CHECK (is_current_flag IN ('Y','N'))
);

-- ============================================================
-- CUSTOMER DIMENSION  (SCD Type 2)
-- ============================================================
CREATE TABLE customer_dim (
    customer_key         NUMBER(10)     NOT NULL,
    cus_ID               NUMBER(10)     NOT NULL,             -- natural key
    cus_name             VARCHAR2(120)  NOT NULL,             -- first + last combined
    cus_email            VARCHAR2(100)  NOT NULL,
    cus_gender           VARCHAR2(10)   NOT NULL,
    cus_city             VARCHAR2(50)   NOT NULL,
    cus_state            VARCHAR2(50)   NOT NULL,
    cus_age_group        VARCHAR2(25)   NOT NULL,             -- derived from cus_DOB against SYSDATE, e.g.
                                                 -- 'Young Adult (18-24)', 'Adult (25-34)' (Type 1)
    cus_loyalty_tier     VARCHAR2(20)   NOT NULL,
    effective_start_date DATE           NOT NULL,
    effective_end_date   DATE           DEFAULT DATE '9999-12-31' NOT NULL,
    is_current_flag      CHAR(1)        DEFAULT 'Y' NOT NULL,
    CONSTRAINT pk_customer_dim PRIMARY KEY (customer_key),
    CONSTRAINT fk_custdim_oltp FOREIGN KEY (cus_ID) REFERENCES customer (cus_ID),
    CONSTRAINT chk_cust_dim_flag CHECK (is_current_flag IN ('Y','N'))
);

-- ============================================================
-- PRODUCT DIMENSION  (SCD Type 2)
-- ============================================================
CREATE TABLE product_dim (
    product_key          NUMBER(10)     NOT NULL,
    product_ID           NUMBER(10)     NOT NULL,
    product_name         VARCHAR2(100)  NOT NULL,
    product_category     VARCHAR2(50)   NOT NULL,
    product_unit_price   NUMBER(10,2)   NOT NULL,
    effective_start_date DATE           NOT NULL,
    effective_end_date   DATE           DEFAULT DATE '9999-12-31' NOT NULL,
    is_current_flag      CHAR(1)        DEFAULT 'Y' NOT NULL,
    CONSTRAINT pk_product_dim PRIMARY KEY (product_key),
    CONSTRAINT fk_proddim_oltp FOREIGN KEY (product_ID) REFERENCES product (product_ID),
    CONSTRAINT chk_prod_dim_flag CHECK (is_current_flag IN ('Y','N'))
);

-- ============================================================
-- SUPPLIER DIMENSION  (SCD Type 2)
-- ============================================================
CREATE TABLE supplier_dim (
    supplier_key         NUMBER(10)     NOT NULL,
    sup_ID               NUMBER(10)     NOT NULL,             -- natural key
    sup_name             VARCHAR2(100)  NOT NULL,
    sup_phone            VARCHAR2(20)   NOT NULL,
    sup_email            VARCHAR2(100)  NOT NULL,
    effective_start_date DATE           NOT NULL,
    effective_end_date   DATE           DEFAULT DATE '9999-12-31' NOT NULL,
    is_current_flag      CHAR(1)        DEFAULT 'Y' NOT NULL,
    CONSTRAINT pk_supplier_dim PRIMARY KEY (supplier_key),
    CONSTRAINT fk_suppdim_oltp FOREIGN KEY (sup_ID) REFERENCES supplier (sup_ID),
    CONSTRAINT chk_supp_dim_flag CHECK (is_current_flag IN ('Y','N'))
);

-- ============================================================
-- SERVICE DIMENSION  (SCD Type 2)
-- ============================================================
CREATE TABLE service_dim (
    service_key          NUMBER(10)     NOT NULL,
    serv_ID              NUMBER(10)     NOT NULL,
    serv_name            VARCHAR2(100)  NOT NULL,
    serv_category        VARCHAR2(50)   NOT NULL,
    serv_price           NUMBER(10,2)   NOT NULL,
    effective_start_date DATE           NOT NULL,
    effective_end_date   DATE           DEFAULT DATE '9999-12-31' NOT NULL,
    is_current_flag      CHAR(1)        DEFAULT 'Y' NOT NULL,
    CONSTRAINT pk_service_dim PRIMARY KEY (service_key),
    CONSTRAINT fk_servdim_oltp FOREIGN KEY (serv_ID) REFERENCES service (serv_ID),
    CONSTRAINT chk_serv_dim_flag CHECK (is_current_flag IN ('Y','N'))
);

-- ############################################################
--                          FACTS
-- ############################################################
-- No sequences, no indexes, no UNIQUE constraints. As drawn in the
-- star-schema ERD, each fact's PRIMARY KEY is the composite of its
-- dimension keys plus the degenerate OLTP ID it carries, and every
-- column is NOT NULL. The incremental loads' NOT EXISTS guards key on
-- the grain: order_fact on (order_ID, product_key), reservation_fact
-- on (res_ID, service_key, staff_key), the other three facts on their
-- degenerate ID alone - each is unique by construction (one degenerate
-- ID / one (order, product) pair resolves to one row of the PK).

-- ============================================================
-- ORDER FACT     Grain: one row per PRODUCT per ORDER
-- The OLTP can carry the same product on two lines of one order;
-- the staging view sums those lines into one fact row, so no
-- order line ID is carried (matches the ERD).
-- ============================================================
CREATE TABLE order_fact (
    date_key             NUMBER(8)      NOT NULL,
    product_key          NUMBER(10)     NOT NULL,
    customer_key         NUMBER(10)     NOT NULL,
    staff_key            NUMBER(10)     NOT NULL,
    branch_key           NUMBER(10)     NOT NULL,
    order_ID             NUMBER(10)     NOT NULL,             -- degenerate dim
    order_status         VARCHAR2(20)   NOT NULL,
    order_qty            NUMBER(5)      NOT NULL,
    order_discount_amt   NUMBER(12,2)   NOT NULL,
    order_tax_amt        NUMBER(12,2)   NOT NULL,
    order_total_amt      NUMBER(12,2)   NOT NULL,             -- qty * product_dim price (version in force
                                              -- on the order date) - discount + tax; no unit
                                              -- price is stored on the line, the dimension holds it
    order_net_amt        NUMBER(12,2)   NOT NULL,             -- order_total_amt - order_tax_amt, i.e.
                                              -- qty * price - discount. REVENUE: the SST in
                                              -- order_total_amt is collected for the government
                                              -- and is not the company's money, so every sales
                                              -- figure should sum THIS column
    CONSTRAINT pk_order_fact PRIMARY KEY (date_key, product_key, customer_key, staff_key, branch_key, order_ID),
    CONSTRAINT fk_of_date      FOREIGN KEY (date_key)     REFERENCES date_dim (date_key),
    CONSTRAINT fk_of_product   FOREIGN KEY (product_key)  REFERENCES product_dim (product_key),
    CONSTRAINT fk_of_customer  FOREIGN KEY (customer_key) REFERENCES customer_dim (customer_key),
    CONSTRAINT fk_of_staff     FOREIGN KEY (staff_key)    REFERENCES staff_dim (staff_key),
    CONSTRAINT fk_of_branch    FOREIGN KEY (branch_key)   REFERENCES branch_dim (branch_key),
    CONSTRAINT fk_of_oltp_ord  FOREIGN KEY (order_ID)     REFERENCES orders (order_ID)
);

-- ============================================================
-- RESERVATION FACT   Grain: one row per SERVICE per STAFF per RESERVATION
-- (the OLTP detail lines of one reservation / service / therapist are
-- summed - in practice always one line). No line ID is carried.
-- date_key = the RESERVATION (appointment) date, not the day the
-- booking was made.
-- ============================================================
CREATE TABLE reservation_fact (
    date_key             NUMBER(8)      NOT NULL,             -- reservation.reservation_date
    customer_key         NUMBER(10)     NOT NULL,
    staff_key            NUMBER(10)     NOT NULL,
    branch_key           NUMBER(10)     NOT NULL,
    service_key          NUMBER(10)     NOT NULL,
    res_ID               NUMBER(10)     NOT NULL,             -- degenerate dim
    res_duration         NUMBER(5)      NOT NULL,             -- derived, actual minutes (end - start)
    res_status           VARCHAR2(20)   NOT NULL,
    start_time           DATE           NOT NULL,
    end_time             DATE           NOT NULL,
    serv_discount_amt    NUMBER(12,2)   NOT NULL,
    serv_tax_amt         NUMBER(12,2)   NOT NULL,
    serv_total_amt       NUMBER(12,2)   NOT NULL,             -- service_dim price (of the date) - disc + tax
    serv_net_amt         NUMBER(12,2)   NOT NULL,             -- serv_total_amt - serv_tax_amt
    CONSTRAINT pk_reservation_fact PRIMARY KEY (date_key, customer_key, staff_key, branch_key, service_key, res_ID),
    CONSTRAINT fk_rf_date      FOREIGN KEY (date_key)     REFERENCES date_dim (date_key),
    CONSTRAINT fk_rf_customer  FOREIGN KEY (customer_key) REFERENCES customer_dim (customer_key),
    CONSTRAINT fk_rf_staff     FOREIGN KEY (staff_key)    REFERENCES staff_dim (staff_key),
    CONSTRAINT fk_rf_branch    FOREIGN KEY (branch_key)   REFERENCES branch_dim (branch_key),
    CONSTRAINT fk_rf_service   FOREIGN KEY (service_key)  REFERENCES service_dim (service_key),
    CONSTRAINT fk_rf_oltp_res  FOREIGN KEY (res_ID)       REFERENCES reservation (res_ID)
);

-- ============================================================
-- PURCHASE FACT    Grain: one row per restocking purchase line
-- ============================================================
CREATE TABLE purchase_fact (
    date_key             NUMBER(8)      NOT NULL,
    supplier_key         NUMBER(10)     NOT NULL,
    branch_key           NUMBER(10)     NOT NULL,
    product_key          NUMBER(10)     NOT NULL,
    purchase_ID          NUMBER(10)     NOT NULL,             -- degenerate dim
    purchase_qty         NUMBER(6)      NOT NULL,
    purchase_unit_cost   NUMBER(10,2)   NOT NULL,
    purchase_total_cost  NUMBER(12,2)   NOT NULL,             -- qty * unit_cost
    CONSTRAINT pk_purchase_fact PRIMARY KEY (date_key, supplier_key, branch_key, product_key, purchase_ID),
    CONSTRAINT fk_pf_date     FOREIGN KEY (date_key)     REFERENCES date_dim (date_key),
    CONSTRAINT fk_pf_supplier FOREIGN KEY (supplier_key) REFERENCES supplier_dim (supplier_key),
    CONSTRAINT fk_pf_branch   FOREIGN KEY (branch_key)   REFERENCES branch_dim (branch_key),
    CONSTRAINT fk_pf_product  FOREIGN KEY (product_key)  REFERENCES product_dim (product_key),
    CONSTRAINT fk_pf_oltp     FOREIGN KEY (purchase_ID)  REFERENCES purchase (purchase_ID)
);

-- ============================================================
-- SALARY PAYMENT FACT   Grain: one row per staff per period
-- branch_key resolved via Staff during ETL (source table has
-- no br_ID by design).
-- ============================================================
CREATE TABLE salary_payment_fact (
    date_key             NUMBER(8)      NOT NULL,
    staff_key            NUMBER(10)     NOT NULL,
    branch_key           NUMBER(10)     NOT NULL,
    sal_pay_ID           NUMBER(10)     NOT NULL,
    pay_period           VARCHAR2(7)    NOT NULL,
    base_amt          NUMBER(12,2)   NOT NULL,
    bonus_amt         NUMBER(12,2)   NOT NULL,
    deduction_amt     NUMBER(12,2)   NOT NULL,
    total_amt         NUMBER(12,2)   NOT NULL,             -- base + bonus - deduction (net pay)
    CONSTRAINT pk_salary_payment_fact PRIMARY KEY (date_key, staff_key, branch_key, sal_pay_ID),
    CONSTRAINT fk_spf_date   FOREIGN KEY (date_key)   REFERENCES date_dim (date_key),
    CONSTRAINT fk_spf_staff  FOREIGN KEY (staff_key)  REFERENCES staff_dim (staff_key),
    CONSTRAINT fk_spf_branch FOREIGN KEY (branch_key) REFERENCES branch_dim (branch_key),
    CONSTRAINT fk_spf_oltp   FOREIGN KEY (sal_pay_ID) REFERENCES salary_payment (sal_pay_ID)
);

-- ============================================================
-- BRANCH UTILS FACT
-- Grain: one row per branch per utility per period
-- util_name (Rent / Electricity / ...) is carried on the row as a
-- degenerate text attribute - there is no utilities dimension.
-- ============================================================
CREATE TABLE branch_utils_fact (
    date_key             NUMBER(8)      NOT NULL,
    branch_key           NUMBER(10)     NOT NULL,
    br_exp_ID            NUMBER(10)     NOT NULL,             -- degenerate dim
    util_name            VARCHAR2(50)   NOT NULL,             -- canonicalised in the staging view
    billing_period       VARCHAR2(7)    NOT NULL,
    payment_amt       NUMBER(12,2)   NOT NULL,
    CONSTRAINT pk_branch_utils_fact PRIMARY KEY (date_key, branch_key, br_exp_ID),
    CONSTRAINT fk_buf_date   FOREIGN KEY (date_key)   REFERENCES date_dim (date_key),
    CONSTRAINT fk_buf_branch FOREIGN KEY (branch_key) REFERENCES branch_dim (branch_key),
    CONSTRAINT fk_buf_oltp   FOREIGN KEY (br_exp_ID)  REFERENCES branch_utils (br_exp_ID)
);


-- ############################################################
--                    VERIFY OBJECTS CREATED
-- ############################################################
SELECT table_name FROM user_tables
WHERE table_name IN ('DATE_DIM','BRANCH_DIM','STAFF_DIM','CUSTOMER_DIM',
                     'PRODUCT_DIM','SUPPLIER_DIM','SERVICE_DIM',
                     'ORDER_FACT','RESERVATION_FACT','PURCHASE_FACT',
                     'SALARY_PAYMENT_FACT','BRANCH_UTILS_FACT')
ORDER BY table_name;
-- expect 12 rows