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
    day_num_week      NUMBER(1),
    day_num_month     NUMBER(2),
    day_num_year      NUMBER(3),
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
    CONSTRAINT pk_date_dim PRIMARY KEY (date_key),
    CONSTRAINT uq_date_dim_date UNIQUE (cal_date)
);

-- ============================================================
-- BRANCH DIMENSION  (SCD Type 2)
-- ============================================================
CREATE TABLE branch_dim (
    branch_key           NUMBER(10)  NOT NULL,   -- surrogate key
    br_ID                NUMBER(10),             -- natural key (OLTP name kept)
    br_name              VARCHAR2(100),
    br_city              VARCHAR2(50),
    br_state             VARCHAR2(50),
    br_email             VARCHAR2(100),
    br_open_date         DATE,
    effective_start_date DATE        NOT NULL,
    effective_end_date   DATE        DEFAULT DATE '9999-12-31',
    is_current_flag      CHAR(1)     DEFAULT 'Y',
    CONSTRAINT pk_branch_dim PRIMARY KEY (branch_key),
    CONSTRAINT fk_branchdim_oltp FOREIGN KEY (br_ID)
        REFERENCES branch (br_ID),
    CONSTRAINT chk_branch_dim_flag CHECK (is_current_flag IN ('Y','N'))
);

-- ============================================================
-- STAFF DIMENSION  (SCD Type 2)
-- br_ID kept so ETL resolves the staff member's branch at
-- transaction time.
-- ============================================================
CREATE TABLE staff_dim (
    staff_key            NUMBER(10)  NOT NULL,
    st_ID                NUMBER(10), 
    br_ID                NUMBER(10),
    st_name              VARCHAR2(120),          -- first + last combined
    st_role              VARCHAR2(50),
    st_position          VARCHAR2(50),
    st_city              VARCHAR2(50),
    st_state             VARCHAR2(50),
    st_gender            VARCHAR2(10),
    st_age               NUMBER(3),
    st_email             VARCHAR2(100),
    st_hire_date         DATE,
    st_salary            NUMBER(10,2),
    st_status            VARCHAR2(20),
    effective_start_date DATE        NOT NULL,
    effective_end_date   DATE        DEFAULT DATE '9999-12-31',
    is_current_flag      CHAR(1)     DEFAULT 'Y',
    CONSTRAINT pk_staff_dim PRIMARY KEY (staff_key),
    CONSTRAINT fk_staffdim_oltp FOREIGN KEY (st_ID)
        REFERENCES staff (st_ID),
    CONSTRAINT fk_staffdim_br_oltp FOREIGN KEY (br_ID)
        REFERENCES branch (br_ID),
    CONSTRAINT chk_staff_dim_flag CHECK (is_current_flag IN ('Y','N'))
);

-- ============================================================
-- CUSTOMER DIMENSION  (SCD Type 2)
-- ============================================================
CREATE TABLE customer_dim (
    customer_key         NUMBER(10)  NOT NULL,
    cus_ID               NUMBER(10),             -- natural key
    cus_name             VARCHAR2(120),          -- first + last combined
    cus_email            VARCHAR2(100),
    cus_gender           VARCHAR2(10),
    cus_age              NUMBER(3),
    cus_age_band         VARCHAR2(15),           -- derived: '18-24','25-34',...
    cus_city             VARCHAR2(50),
    cus_state            VARCHAR2(50),
    cus_loyalty_tier     VARCHAR2(20),
    cus_reg_date         DATE,
    effective_start_date DATE        NOT NULL,
    effective_end_date   DATE        DEFAULT DATE '9999-12-31',
    is_current_flag      CHAR(1)     DEFAULT 'Y',
    CONSTRAINT pk_customer_dim PRIMARY KEY (customer_key),
    CONSTRAINT fk_custdim_oltp FOREIGN KEY (cus_ID)
        REFERENCES customer (cus_ID),
    CONSTRAINT chk_cust_dim_flag CHECK (is_current_flag IN ('Y','N'))
);

-- ============================================================
-- PRODUCT DIMENSION  (SCD Type 2)
-- ============================================================
CREATE TABLE product_dim (
    product_key          NUMBER(10)  NOT NULL,
    product_ID           NUMBER(10),
    product_name         VARCHAR2(100),
    product_brand        VARCHAR2(50),
    product_category     VARCHAR2(50),
    product_unit_price   NUMBER(10,2),
    effective_start_date DATE        NOT NULL,
    effective_end_date   DATE        DEFAULT DATE '9999-12-31',
    is_current_flag      CHAR(1)     DEFAULT 'Y',
    CONSTRAINT pk_product_dim PRIMARY KEY (product_key),
    CONSTRAINT fk_proddim_oltp FOREIGN KEY (product_ID)
        REFERENCES product (product_ID),
    CONSTRAINT chk_prod_dim_flag CHECK (is_current_flag IN ('Y','N'))
);

-- ============================================================
-- SUPPLIER DIMENSION  (SCD Type 2)
-- ============================================================
CREATE TABLE supplier_dim (
    supplier_key         NUMBER(10)  NOT NULL,
    sup_ID               NUMBER(10),             -- natural key
    sup_name             VARCHAR2(100),
    sup_phone            VARCHAR2(20),
    sup_email            VARCHAR2(100),
    effective_start_date DATE        NOT NULL,
    effective_end_date   DATE        DEFAULT DATE '9999-12-31',
    is_current_flag      CHAR(1)     DEFAULT 'Y',
    CONSTRAINT pk_supplier_dim PRIMARY KEY (supplier_key),
    CONSTRAINT fk_suppdim_oltp FOREIGN KEY (sup_ID)
        REFERENCES supplier (sup_ID),
    CONSTRAINT chk_supp_dim_flag CHECK (is_current_flag IN ('Y','N'))
);

-- ============================================================
-- SERVICE DIMENSION  (SCD Type 2)
-- ============================================================
CREATE TABLE service_dim (
    service_key          NUMBER(10)  NOT NULL,
    serv_ID              NUMBER(10),
    serv_name            VARCHAR2(100),
    serv_category        VARCHAR2(50),
    serv_price           NUMBER(10,2),
    serv_duration        NUMBER(4),              -- standard minutes
    effective_start_date DATE        NOT NULL,
    effective_end_date   DATE        DEFAULT DATE '9999-12-31',
    is_current_flag      CHAR(1)     DEFAULT 'Y',
    CONSTRAINT pk_service_dim PRIMARY KEY (service_key),
    CONSTRAINT fk_servdim_oltp FOREIGN KEY (serv_ID)
        REFERENCES service (serv_ID),
    CONSTRAINT chk_serv_dim_flag CHECK (is_current_flag IN ('Y','N'))
);

-- ============================================================
-- BRANCH UTILS CATEGORY DIMENSION  (SCD Type 1 lookup)
-- ============================================================
CREATE TABLE branch_utils_dim (
    branch_utils_key     NUMBER(10)  NOT NULL,
    br_utils_ID          NUMBER(10),             -- natural key
    util_name            VARCHAR2(50),
    util_category        VARCHAR2(20),           -- derived: 'Fixed'/'Variable'
    CONSTRAINT pk_branch_utils_dim PRIMARY KEY (branch_utils_key),
    CONSTRAINT fk_utilsdim_oltp FOREIGN KEY (br_utils_ID)
        REFERENCES branch_utils_category (br_utils_ID),
    CONSTRAINT uq_branch_utils_nk UNIQUE (br_utils_ID)
);


-- ############################################################
--                          FACTS
-- ############################################################
-- No sequences, no indexes. PKs are the degenerate dimension
-- IDs carried from the source system (OLTP names kept).

-- ============================================================
-- ORDER FACT     Grain: one row per product line on an order
-- ============================================================
CREATE TABLE order_fact (
    date_key           NUMBER(8)    NOT NULL,
    product_key        NUMBER(10)   NOT NULL,
    customer_key       NUMBER(10)   NOT NULL,
    staff_key          NUMBER(10)   NOT NULL,
    branch_key         NUMBER(10)   NOT NULL,
    order_ID           NUMBER(10)   NOT NULL,   -- degenerate dim
    order_det_ID       NUMBER(10)   NOT NULL,   -- degenerate dim / PK
    order_status       VARCHAR2(20),
    order_qty          NUMBER(5),
    order_unit_price   NUMBER(10,2),
    order_gross_amt    NUMBER(12,2),            -- qty * unit_price
    order_discount_amt NUMBER(12,2),
    order_tax_amt      NUMBER(12,2),
    order_total_amt    NUMBER(12,2),           -- gross - disc + tax
    CONSTRAINT pk_order_fact PRIMARY KEY (order_det_ID),
    CONSTRAINT fk_of_date      FOREIGN KEY (date_key)     REFERENCES date_dim (date_key),
    CONSTRAINT fk_of_product   FOREIGN KEY (product_key)  REFERENCES product_dim (product_key),
    CONSTRAINT fk_of_customer  FOREIGN KEY (customer_key) REFERENCES customer_dim (customer_key),
    CONSTRAINT fk_of_staff     FOREIGN KEY (staff_key)    REFERENCES staff_dim (staff_key),
    CONSTRAINT fk_of_branch    FOREIGN KEY (branch_key)   REFERENCES branch_dim (branch_key),
    CONSTRAINT fk_of_oltp_ord  FOREIGN KEY (order_ID)     REFERENCES orders (order_ID),
    CONSTRAINT fk_of_oltp_det  FOREIGN KEY (order_det_ID) REFERENCES order_detail (order_det_ID)
);

-- ============================================================
-- RESERVATION FACT   Grain: one row per service line booked
-- ============================================================
CREATE TABLE reservation_fact (
    date_key             NUMBER(8)  NOT NULL,
    customer_key         NUMBER(10) NOT NULL,
    staff_key            NUMBER(10) NOT NULL,
    branch_key           NUMBER(10) NOT NULL,
    service_key          NUMBER(10) NOT NULL,
    res_ID               NUMBER(10) NOT NULL,
    res_det_ID           NUMBER(10) NOT NULL,
    res_status           VARCHAR2(20),
    start_time           DATE,
    end_time             DATE,
    start_hour           NUMBER(2),             -- derived, for peak-hour analysis
    res_duration         NUMBER(5),             -- derived, actual minutes
    serv_price           NUMBER(10,2),
    serv_discount_amt    NUMBER(12,2),
    serv_tax_amt         NUMBER(12,2),
    serv_total_amt       NUMBER(12,2),
    CONSTRAINT pk_reservation_fact PRIMARY KEY (res_det_ID),
    CONSTRAINT fk_rf_date      FOREIGN KEY (date_key)     REFERENCES date_dim (date_key),
    CONSTRAINT fk_rf_customer  FOREIGN KEY (customer_key) REFERENCES customer_dim (customer_key),
    CONSTRAINT fk_rf_staff     FOREIGN KEY (staff_key)    REFERENCES staff_dim (staff_key),
    CONSTRAINT fk_rf_branch    FOREIGN KEY (branch_key)   REFERENCES branch_dim (branch_key),
    CONSTRAINT fk_rf_service   FOREIGN KEY (service_key)  REFERENCES service_dim (service_key),
    CONSTRAINT fk_rf_oltp_res  FOREIGN KEY (res_ID)       REFERENCES reservation (res_ID),
    CONSTRAINT fk_rf_oltp_det  FOREIGN KEY (res_det_ID)   REFERENCES reservation_detail (res_det_ID)
);

-- ============================================================
-- PURCHASE FACT    Grain: one row per restocking purchase line
-- ============================================================
CREATE TABLE purchase_fact (
    date_key            NUMBER(8)   NOT NULL,
    supplier_key        NUMBER(10)  NOT NULL,
    branch_key          NUMBER(10)  NOT NULL,
    product_key         NUMBER(10)  NOT NULL,
    purchase_ID         NUMBER(10)  NOT NULL,
    purchase_qty        NUMBER(6),
    purchase_unit_cost  NUMBER(10,2),
    purchase_total_cost NUMBER(12,2),           -- qty * unit_cost
    CONSTRAINT pk_purchase_fact PRIMARY KEY (purchase_ID),
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
    date_key          NUMBER(8)     NOT NULL,
    staff_key         NUMBER(10)    NOT NULL,
    branch_key        NUMBER(10)    NOT NULL,
    sal_pay_ID        NUMBER(10)    NOT NULL,
    pay_period        VARCHAR2(7),
    base_amount       NUMBER(12,2),
    bonus_amount      NUMBER(12,2),
    deduction_amount  NUMBER(12,2),
    gross_amount      NUMBER(12,2),             -- base + bonus
    net_amount        NUMBER(12,2),             -- base + bonus - deduction
    CONSTRAINT pk_salary_payment_fact PRIMARY KEY (sal_pay_ID),
    CONSTRAINT fk_spf_date   FOREIGN KEY (date_key)   REFERENCES date_dim (date_key),
    CONSTRAINT fk_spf_staff  FOREIGN KEY (staff_key)  REFERENCES staff_dim (staff_key),
    CONSTRAINT fk_spf_branch FOREIGN KEY (branch_key) REFERENCES branch_dim (branch_key),
    CONSTRAINT fk_spf_oltp   FOREIGN KEY (sal_pay_ID) REFERENCES salary_payment (sal_pay_ID)
);

-- ============================================================
-- BRANCH EXPENSE FACT
-- Grain: one row per branch per utility category per period
-- ============================================================
CREATE TABLE branch_expense_fact (
    date_key          NUMBER(8)     NOT NULL,
    branch_key        NUMBER(10)    NOT NULL,
    branch_utils_key  NUMBER(10)    NOT NULL,
    br_exp_ID         NUMBER(10)    NOT NULL,   -- degenerate dim / PK
    billing_period    VARCHAR2(7),
    payment_amount    NUMBER(12,2),
    CONSTRAINT pk_branch_expense_fact PRIMARY KEY (br_exp_ID),
    CONSTRAINT fk_bef_date   FOREIGN KEY (date_key)         REFERENCES date_dim (date_key),
    CONSTRAINT fk_bef_branch FOREIGN KEY (branch_key)       REFERENCES branch_dim (branch_key),
    CONSTRAINT fk_bef_utils  FOREIGN KEY (branch_utils_key) REFERENCES branch_utils_dim (branch_utils_key),
    CONSTRAINT fk_bef_oltp   FOREIGN KEY (br_exp_ID)        REFERENCES branch_expense (br_exp_ID)
);


-- ############################################################
--                    VERIFY OBJECTS CREATED
-- ############################################################
SELECT table_name FROM user_tables
WHERE table_name IN ('DATE_DIM','BRANCH_DIM','STAFF_DIM','CUSTOMER_DIM',
                     'PRODUCT_DIM','SUPPLIER_DIM','SERVICE_DIM','BRANCH_UTILS_DIM',
                     'ORDER_FACT','RESERVATION_FACT','PURCHASE_FACT',
                     'SALARY_PAYMENT_FACT','BRANCH_EXPENSE_FACT')
ORDER BY table_name;
-- expect 13 rows