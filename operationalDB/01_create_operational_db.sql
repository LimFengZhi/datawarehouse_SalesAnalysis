-- ============================================================
-- DWH Assignment - Operational Database (OLTP)
-- Oracle SQL*Plus - CREATE TABLE script
-- Naming convention: table prefix + snake_case
--   Branch->br_, Staff->st_, Customer->cus_, Product->product_,
--   Purchase->purchase_, Supplier->sup_, Service->serv_,
--   Order->order_, OrderDetail->order_det_,
--   Reservation->res_, ReservationDetail->res_det_,
--   Salary_Payment->sal_pay_, Branch_Expense->br_exp_,
--   Branch_Utils_Category->br_utils_
-- NOTE: "ORDER" is a reserved word in Oracle, so the table
--       is named ORDERS.
-- Run order = dependency order (parents before children).
-- ============================================================

-- ---------- Drop tables if re-running (children first) ----------
-- DROP TABLE order_detail        CASCADE CONSTRAINTS;
-- DROP TABLE orders              CASCADE CONSTRAINTS;
-- DROP TABLE reservation_detail  CASCADE CONSTRAINTS;
-- DROP TABLE reservation         CASCADE CONSTRAINTS;
-- DROP TABLE purchase            CASCADE CONSTRAINTS;
-- DROP TABLE salary_payment      CASCADE CONSTRAINTS;
-- DROP TABLE branch_expense      CASCADE CONSTRAINTS;
-- DROP TABLE staff               CASCADE CONSTRAINTS;
-- DROP TABLE branch_utils_category CASCADE CONSTRAINTS;
-- DROP TABLE customer            CASCADE CONSTRAINTS;
-- DROP TABLE service             CASCADE CONSTRAINTS;
-- DROP TABLE product             CASCADE CONSTRAINTS;
-- DROP TABLE supplier            CASCADE CONSTRAINTS;
-- DROP TABLE branch              CASCADE CONSTRAINTS;

-- ============================================================
-- 1. BRANCH
-- ============================================================
CREATE TABLE branch (
    br_ID            NUMBER(10)      NOT NULL,
    br_name          VARCHAR2(100)   NOT NULL,
    br_address_line  VARCHAR2(150),
    br_city          VARCHAR2(50),
    br_state         VARCHAR2(50),
    br_postcode      VARCHAR2(10),
    br_phone         VARCHAR2(20),
    br_email         VARCHAR2(100),
    br_open_date     DATE,
    CONSTRAINT pk_branch PRIMARY KEY (br_ID)
);

-- ============================================================
-- 2. STAFF  (BranchID lives HERE - owner of the branch fact)
-- ============================================================
CREATE TABLE staff (
    st_ID            NUMBER(10)      NOT NULL,
    br_ID            NUMBER(10)      NOT NULL,
    st_first_name    VARCHAR2(50)    NOT NULL,
    st_last_name     VARCHAR2(50)    NOT NULL,
    st_role          VARCHAR2(50),
    st_position      VARCHAR2(50),
    st_address_line  VARCHAR2(150),
    st_city          VARCHAR2(50),
    st_state         VARCHAR2(50),
    st_postcode      VARCHAR2(10),
    st_DOB           DATE,
    st_gender        VARCHAR2(10),
    st_email         VARCHAR2(100),
    st_phone         VARCHAR2(20),
    st_hire_date     DATE            NOT NULL,
    st_salary        NUMBER(10,2),
    st_status        VARCHAR2(20)    DEFAULT 'Active',
    CONSTRAINT pk_staff PRIMARY KEY (st_ID),
    CONSTRAINT fk_staff_branch FOREIGN KEY (br_ID)
        REFERENCES branch (br_ID),
    CONSTRAINT chk_staff_gender
        CHECK (st_gender IN ('Male','Female')),
    CONSTRAINT chk_staff_status
        CHECK (st_status IN ('Active','Inactive','Resigned'))
);

-- ============================================================
-- 3. CUSTOMER
--    (cus_age kept to match ERD; consider deriving from DOB)
-- ============================================================
CREATE TABLE customer (
    cus_ID           NUMBER(10)      NOT NULL,
    cus_first_name   VARCHAR2(50)    NOT NULL,
    cus_last_name    VARCHAR2(50)    NOT NULL,
    cus_age          NUMBER(3),
    cus_gender       VARCHAR2(10),
    cus_phone        VARCHAR2(20),
    cus_DOB          DATE,
    cus_email        VARCHAR2(100),
    cus_loyalty_tier VARCHAR2(20),
    cus_address_line VARCHAR2(150),
    cus_city         VARCHAR2(50),
    cus_state        VARCHAR2(50),
    cus_postcode     VARCHAR2(10),
    cus_reg_date     DATE            DEFAULT SYSDATE,
    CONSTRAINT pk_customer PRIMARY KEY (cus_ID),
    CONSTRAINT chk_cus_gender
        CHECK (cus_gender IN ('Male','Female'))
);

-- ============================================================
-- 4. PRODUCT
-- ============================================================
CREATE TABLE product (
    product_ID         NUMBER(10)    NOT NULL,
    product_name       VARCHAR2(100) NOT NULL,
    product_brand      VARCHAR2(50),
    product_category   VARCHAR2(50),
    product_desc       VARCHAR2(300),
    product_unit_price NUMBER(10,2)  NOT NULL,
    CONSTRAINT pk_product PRIMARY KEY (product_ID),
    CONSTRAINT chk_product_price CHECK (product_unit_price >= 0)
);

-- ============================================================
-- 5. SUPPLIER
-- ============================================================
CREATE TABLE supplier (
    sup_ID           NUMBER(10)      NOT NULL,
    sup_name         VARCHAR2(100)   NOT NULL,
    sup_phone        VARCHAR2(20),
    sup_email        VARCHAR2(100),
    CONSTRAINT pk_supplier PRIMARY KEY (sup_ID)
);

-- ============================================================
-- 6. SERVICE
-- ============================================================
CREATE TABLE service (
    serv_ID          NUMBER(10)      NOT NULL,
    serv_name        VARCHAR2(100)   NOT NULL,
    serv_category    VARCHAR2(50),
    serv_description VARCHAR2(300),
    serv_price       NUMBER(10,2)    NOT NULL,
    CONSTRAINT pk_service PRIMARY KEY (serv_ID),
    CONSTRAINT chk_serv_price CHECK (serv_price >= 0)
);

-- ============================================================
-- 7. BRANCH_UTILS_CATEGORY  (lookup)
-- ============================================================
CREATE TABLE branch_utils_category (
    br_utils_ID      NUMBER(10)      NOT NULL,
    util_name        VARCHAR2(50)    NOT NULL,
    CONSTRAINT pk_br_utils_cat PRIMARY KEY (br_utils_ID),
    CONSTRAINT uq_br_utils_name UNIQUE (util_name)
);

-- ============================================================
-- 8. BRANCH_EXPENSE
-- ============================================================
CREATE TABLE branch_expense (
    br_exp_ID        NUMBER(10)      NOT NULL,
    br_ID            NUMBER(10)      NOT NULL,
    br_utils_ID      NUMBER(10)      NOT NULL,
    billing_period   VARCHAR2(7),          -- format 'YYYY-MM'
    payment_amount   NUMBER(10,2)    NOT NULL,
    payment_date     DATE,
    CONSTRAINT pk_branch_expense PRIMARY KEY (br_exp_ID),
    CONSTRAINT fk_brexp_branch FOREIGN KEY (br_ID)
        REFERENCES branch (br_ID),
    CONSTRAINT fk_brexp_utils FOREIGN KEY (br_utils_ID)
        REFERENCES branch_utils_category (br_utils_ID),
    CONSTRAINT chk_brexp_amount CHECK (payment_amount >= 0)
);

-- ============================================================
-- 9. SALARY_PAYMENT  (no br_ID - derived via staff)
-- ============================================================
CREATE TABLE salary_payment (
    sal_pay_ID       NUMBER(10)      NOT NULL,
    st_ID            NUMBER(10)      NOT NULL,
    pay_period       VARCHAR2(7)     NOT NULL,   -- 'YYYY-MM'
    base_amount      NUMBER(10,2)    NOT NULL,
    bonus_amount     NUMBER(10,2)    DEFAULT 0,
    deduction_amount NUMBER(10,2)    DEFAULT 0,
    payment_date     DATE            NOT NULL,
    CONSTRAINT pk_salary_payment PRIMARY KEY (sal_pay_ID),
    CONSTRAINT fk_salpay_staff FOREIGN KEY (st_ID)
        REFERENCES staff (st_ID),
    CONSTRAINT chk_salpay_base CHECK (base_amount >= 0)
);

-- ============================================================
-- 10. ORDERS  ("ORDER" is reserved in Oracle)
-- ============================================================
CREATE TABLE orders (
    order_ID         NUMBER(10)      NOT NULL,
    cus_ID           NUMBER(10)      NOT NULL,
    br_ID            NUMBER(10)      NOT NULL,
    st_ID            NUMBER(10)      NOT NULL,
    order_date       DATE            DEFAULT SYSDATE NOT NULL,
    order_status     VARCHAR2(20)    DEFAULT 'Pending',
    CONSTRAINT pk_orders PRIMARY KEY (order_ID),
    CONSTRAINT fk_orders_customer FOREIGN KEY (cus_ID)
        REFERENCES customer (cus_ID),
    CONSTRAINT fk_orders_branch FOREIGN KEY (br_ID)
        REFERENCES branch (br_ID),
    CONSTRAINT fk_orders_staff FOREIGN KEY (st_ID)
        REFERENCES staff (st_ID),
    CONSTRAINT chk_order_status
        CHECK (order_status IN
            ('Pending','Processing','Completed','Cancelled'))
);

-- ============================================================
-- 11. ORDER_DETAIL
--     order_unit_price = price charged at time of sale
--     (remove if you decided against it)
-- ============================================================
CREATE TABLE order_detail (
    order_det_ID     NUMBER(10)      NOT NULL,
    order_ID         NUMBER(10)      NOT NULL,
    product_ID       NUMBER(10)      NOT NULL,
    order_quantity   NUMBER(5)       NOT NULL,
    order_unit_price NUMBER(10,2)    NOT NULL,
    order_discount   NUMBER(10,2)    DEFAULT 0,
    order_tax        NUMBER(10,2)    DEFAULT 0,
    CONSTRAINT pk_order_detail PRIMARY KEY (order_det_ID),
    CONSTRAINT fk_orddet_order FOREIGN KEY (order_ID)
        REFERENCES orders (order_ID),
    CONSTRAINT fk_orddet_product FOREIGN KEY (product_ID)
        REFERENCES product (product_ID),
    CONSTRAINT chk_orddet_qty CHECK (order_quantity > 0)
);

-- ============================================================
-- 12. RESERVATION
-- ============================================================
CREATE TABLE reservation (
    res_ID           NUMBER(10)      NOT NULL,
    cus_ID           NUMBER(10)      NOT NULL,
    br_ID            NUMBER(10)      NOT NULL,
    booking_date     DATE            DEFAULT SYSDATE NOT NULL,
    res_status       VARCHAR2(20)    DEFAULT 'Booked',
    CONSTRAINT pk_reservation PRIMARY KEY (res_ID),
    CONSTRAINT fk_res_customer FOREIGN KEY (cus_ID)
        REFERENCES customer (cus_ID),
    CONSTRAINT fk_res_branch FOREIGN KEY (br_ID)
        REFERENCES branch (br_ID),
    CONSTRAINT chk_res_status
        CHECK (res_status IN
            ('Booked','Confirmed','Completed','Cancelled','No-Show'))
);

-- ============================================================
-- 13. RESERVATION_DETAIL
-- ============================================================
CREATE TABLE reservation_detail (
    res_det_ID       NUMBER(10)      NOT NULL,
    res_ID           NUMBER(10)      NOT NULL,
    st_ID            NUMBER(10)      NOT NULL,
    serv_ID          NUMBER(10)      NOT NULL,
    start_time       DATE,           -- Oracle DATE stores date+time
    end_time         DATE,
    serv_discount    NUMBER(10,2)    DEFAULT 0,
    serv_tax         NUMBER(10,2)    DEFAULT 0,
    CONSTRAINT pk_res_detail PRIMARY KEY (res_det_ID),
    CONSTRAINT fk_resdet_res FOREIGN KEY (res_ID)
        REFERENCES reservation (res_ID),
    CONSTRAINT fk_resdet_staff FOREIGN KEY (st_ID)
        REFERENCES staff (st_ID),
    CONSTRAINT fk_resdet_service FOREIGN KEY (serv_ID)
        REFERENCES service (serv_ID)
);

-- ============================================================
-- 14. PURCHASE
-- ============================================================
CREATE TABLE purchase (
    purchase_ID        NUMBER(10)    NOT NULL,
    product_ID         NUMBER(10)    NOT NULL,
    br_ID              NUMBER(10)    NOT NULL,
    sup_ID             NUMBER(10)    NOT NULL,
    purchase_qty       NUMBER(6)     NOT NULL,
    purchase_date      DATE          DEFAULT SYSDATE NOT NULL,
    purchase_unit_cost NUMBER(10,2)  NOT NULL,
    CONSTRAINT pk_purchase PRIMARY KEY (purchase_ID),
    CONSTRAINT fk_pur_product FOREIGN KEY (product_ID)
        REFERENCES product (product_ID),
    CONSTRAINT fk_pur_branch FOREIGN KEY (br_ID)
        REFERENCES branch (br_ID),
    CONSTRAINT fk_pur_supplier FOREIGN KEY (sup_ID)
        REFERENCES supplier (sup_ID),
    CONSTRAINT chk_pur_qty CHECK (purchase_qty > 0),
    CONSTRAINT chk_pur_cost CHECK (purchase_unit_cost >= 0)
);

-- ============================================================
-- End of script
-- ============================================================
