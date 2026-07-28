-- =====================================================================
-- KAREYA — DEMO SEED (master data only)
-- ---------------------------------------------------------------------
-- Fills a Silo with the reference data you would otherwise spend hours
-- typing: staff, clients, vendors, products, stock, and a starter catalog
-- for every industry module — so no screen opens empty.
--
-- WHAT THIS DELIBERATELY DOES NOT SEED: transactions. No invoices, sales,
-- payments, stock movements, check-ins or milling runs. Those are created
-- by the app so that postJournal / recordStockMovement / the status
-- pipelines actually run. Inserting them here would bypass that logic and
-- give you a database that looks fine while hiding the very bugs you are
-- testing for. Create a few by hand instead — that IS the test.
--
-- HOW TO RUN
--   1. Open your Silo in Supabase Studio -> SQL Editor.
--   2. Change the email on the ONE marked line below to your Google login.
--   3. Run the whole file. Safe to re-run (idempotent).
--   4. In the app: Accounting -> Accounts -> "Install Standard Accounts".
--      Nothing posts to the ledger until you do — postings silently no-op.
--
-- To start over: run demo-reset.sql in the same folder.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. YOU. RLS resolves a user by employees.user_id = auth.uid() OR
--    employees.email = the JWT email, so your address is all that's needed.
--    Every role is granted so no module is hidden while you test.
-- ---------------------------------------------------------------------
DO $seed$
DECLARE
  v_email text := 'sengtha@gmail.com';   -- <<<<<< EDIT THIS LINE ONLY
BEGIN
  INSERT INTO employees (name, email, roles, department, status, work_type, work_mode, base_salary)
  VALUES ('Demo Owner', v_email, ARRAY[
      'Admin','Founder','Manager','HR','HR Manager','Accountant','Sales Lead','Marketing','Support',
      'Teacher','Lab','Grants','Clinician','Nurse','Reception','FrontDesk','Housekeeping','Waiter',
      'Kitchen','Cashier','Pharmacist','Loan Officer','Property Manager','Mechanic','Stylist',
      'Site Manager','Dispatcher','Driver','Pawnbroker','Trainer','Event Planner','Rental Agent',
      'Travel Agent','Guide','Goldsmith','Teller','Water Agent','Laundry Staff','Farm Manager',
      'Field Worker','Optometrist','Veterinarian','Broker','Attendant','Parking Attendant',
      'Funeral Director','Insurance Agent',
      -- wave-2 verticals
      'Sales Agent','Pump Attendant','Mill Operator','Technician','Site Supervisor','Host',
      'Freight Officer','Customs Broker','Line Supervisor','Merchandiser',
      'Lawyer','Notary','Paralegal','Librarian','Gas Agent','Community Manager'
    ], 'Management', 'active', 'fixed', 'onsite', 1500)
  ON CONFLICT (email) DO UPDATE
    SET roles = EXCLUDED.roles, status = 'active', department = 'Management';
END $seed$;

-- ---------------------------------------------------------------------
-- 1. Departments + colleagues (populate every assignee dropdown)
-- ---------------------------------------------------------------------
INSERT INTO departments (name, description)
SELECT v.name, v.description FROM (VALUES
  ('Management','Owners and managers'), ('Finance','Accounting and treasury'),
  ('Operations','Day-to-day delivery'),  ('Sales','Sales and CRM'),
  ('Support','Customer service'),        ('Production','Workshop and factory floor')
) AS v(name, description)
WHERE NOT EXISTS (SELECT 1 FROM departments d WHERE d.name = v.name);

INSERT INTO employees (name, email, roles, department, status, base_salary)
SELECT v.name, v.email, v.roles, v.department, 'active', v.salary FROM (VALUES
  ('Sokha Chan',    'sokha.demo@kareya.test',   ARRAY['Accountant','Manager'],       'Finance',    900),
  ('Dara Prak',     'dara.demo@kareya.test',    ARRAY['Sales Lead'],                 'Sales',      750),
  ('Bopha Sok',     'bopha.demo@kareya.test',   ARRAY['HR Manager'],                 'Management', 850),
  ('Vichea Nou',    'vichea.demo@kareya.test',  ARRAY['Cashier','Attendant'],        'Operations', 400),
  ('Sreymom Ly',    'sreymom.demo@kareya.test', ARRAY['Support','Reception'],        'Support',    450),
  ('Piseth Meas',   'piseth.demo@kareya.test',  ARRAY['Driver','Field Worker'],      'Operations', 380),
  ('Chanthou Kim',  'chanthou.demo@kareya.test',ARRAY['Technician','Mechanic'],      'Production', 520),
  ('Rithy San',     'rithy.demo@kareya.test',   ARRAY['Line Supervisor','Manager'],  'Production', 600)
) AS v(name, email, roles, department, salary)
WHERE NOT EXISTS (SELECT 1 FROM employees e WHERE e.email = v.email);

-- ---------------------------------------------------------------------
-- 2. Customers and suppliers
-- ---------------------------------------------------------------------
INSERT INTO clients (name, company_name, email, phone, type, status)
SELECT v.* FROM (VALUES
  ('Ratanak Hong','Angkor Trading Co.','ratanak@angkor.test','012 345 678','client','active'),
  ('Sophea Chea','Mekong Foods Ltd.','sophea@mekong.test','012 111 222','client','active'),
  ('Kimhak Or','Riverside Hotel','kimhak@riverside.test','012 333 444','client','active'),
  ('Nita Seng','Phnom Penh Clinic','nita@ppclinic.test','012 555 666','client','lead'),
  ('Vuthy Lim','Silk Road Logistics','vuthy@silkroad.test','012 777 888','partner','active'),
  ('Chenda Mao','Bayon Garments','chenda@bayon.test','012 999 000','client','active'),
  ('Samnang Ke','Tonle Construction','samnang@tonle.test','011 222 333','client','active'),
  ('Leakena Pich','Golden Rice Export','leakena@goldenrice.test','011 444 555','client','lead')
) AS v(name, company_name, email, phone, type, status)
WHERE NOT EXISTS (SELECT 1 FROM clients c WHERE c.email = v.email);

INSERT INTO vendors (name, email, phone, address, tax_id, lead_time_days, is_preferred)
SELECT v.* FROM (VALUES
  ('Sokimex Supplies','sales@sokimex.test','023 111 111','St 271, Phnom Penh','K001-1111', 5, true),
  ('Camko Wholesale','info@camko.test','023 222 222','St 128, Phnom Penh','K001-2222', 7, false),
  ('Mekong Packaging','order@mekongpack.test','023 333 333','Kandal','K001-3333', 10, false),
  ('Delta Hardware','sales@delta.test','023 444 444','Toul Kork','K001-4444', 3, true),
  ('Asia Fuel Depot','fuel@asiadepot.test','023 555 555','Sihanoukville','K001-5555', 2, true)
) AS v(name, email, phone, address, tax_id, lead_time_days, is_preferred)
WHERE NOT EXISTS (SELECT 1 FROM vendors x WHERE x.name = v.name);

-- ---------------------------------------------------------------------
-- 3. Catalog, stock and warehouses (Sales + Inventory + POS)
-- ---------------------------------------------------------------------
INSERT INTO products_services (name, type, price, unit, description)
SELECT v.* FROM (VALUES
  ('Consulting — standard','service', 45.00,'hour','Professional services, billed hourly'),
  ('Consulting — senior','service', 80.00,'hour','Senior consultant rate'),
  ('Installation','service',120.00,'job','On-site installation'),
  ('Annual maintenance','service',600.00,'year','Support contract'),
  ('Delivery (city)','service',  5.00,'trip','Phnom Penh delivery'),
  ('Bottled water 20L','product', 2.50,'bottle','Refillable 20 litre bottle'),
  ('Rice 50kg sack','product',   42.00,'sack','Premium jasmine rice'),
  ('Cement 50kg','product',       7.50,'bag','Portland cement'),
  ('Office chair','product',     65.00,'unit','Ergonomic mesh chair'),
  ('Laptop 14"','product',      520.00,'unit','Business laptop')
) AS v(name, type, price, unit, description)
WHERE NOT EXISTS (SELECT 1 FROM products_services p WHERE p.name = v.name);

INSERT INTO warehouses (name, code, address, is_default)
SELECT v.* FROM (VALUES
  ('Main Warehouse','WH-MAIN','Phnom Penh', true),
  ('Siem Reap Depot','WH-SR','Siem Reap', false)
) AS v(name, code, address, is_default)
WHERE NOT EXISTS (SELECT 1 FROM warehouses w WHERE w.code = v.code);

INSERT INTO stock_items (sku, name, category, unit, cost_price, sale_price, quantity, reorder_level, location)
SELECT v.* FROM (VALUES
  ('SKU-1001','Bottled water 20L','Beverage','bottle', 1.20,  2.50, 240, 50,'Main Warehouse'),
  ('SKU-1002','Rice 50kg sack','Food','sack',         36.00, 42.00,  80, 20,'Main Warehouse'),
  ('SKU-1003','Cement 50kg','Building','bag',          6.10,  7.50, 300, 60,'Main Warehouse'),
  ('SKU-1004','Office chair','Furniture','unit',      44.00, 65.00,  25,  8,'Main Warehouse'),
  ('SKU-1005','Laptop 14"','Electronics','unit',     430.00,520.00,  12,  4,'Main Warehouse'),
  ('SKU-1006','Printer ink','Consumable','unit',      11.00, 18.00,   6, 10,'Main Warehouse'),  -- below reorder on purpose
  ('SKU-1007','Safety helmet','Safety','unit',         5.50,  9.00,  40, 15,'Siem Reap Depot'),
  ('SKU-1008','Engine oil 4L','Automotive','can',     14.00, 22.00,   9, 12,'Siem Reap Depot')  -- below reorder on purpose
) AS v(sku, name, category, unit, cost_price, sale_price, quantity, reorder_level, location)
WHERE NOT EXISTS (SELECT 1 FROM stock_items s WHERE s.sku = v.sku);

-- Currencies. The Chart of Accounts is installed from the app
-- (Accounting -> Accounts -> Install Standard Accounts).
INSERT INTO currencies (code, name, symbol, rate_to_base, is_base, is_active, decimals)
SELECT v.* FROM (VALUES
  ('USD','US Dollar','$',    1.0,    true,  true, 2),
  ('KHR','Khmer Riel','៛', 4100.0,  false, true, 0)
) AS v(code, name, symbol, rate_to_base, is_base, is_active, decimals)
WHERE NOT EXISTS (SELECT 1 FROM currencies c WHERE c.code = v.code);

-- ---------------------------------------------------------------------
-- 4. Turn every module on, so nothing is hidden while you test.
--    (Setup Advisor -> Manage modules can trim this later.)
-- ---------------------------------------------------------------------
INSERT INTO workspace_config (id, active_modules, onboarded, business_type, business_size, industry, business_description)
VALUES (true, to_jsonb(ARRAY[
  'dashboard','advisor','publicfeed','discuss','settings','hr','attendance','leave','schedule','learning',
  'accounting','inventory','sales','marketing','support','projects','documents','fleet','forms','connect','public',
  'academy','lab','grants','clinic','hotel','restaurant','pharmacy','retail','microfinance','property',
  'workshop','salon','construction','logistics','pawn','gym','events','vehiclerental','travel','goldsmith',
  'moneyexchange','water','laundry','farm','optical','vet','brokerage','gaming','parking','funeral','insurance',
  'developer','fuel','ricemill','electronics','manpower','ktv','freight','garment','legal','library','lpg','coworking'
]), true, 'demo', 'small', 'multi', 'Demo workspace seeded for testing every module.')
ON CONFLICT (id) DO UPDATE
  SET active_modules = EXCLUDED.active_modules, onboarded = true, updated_at = now();

-- ---------------------------------------------------------------------
-- 5. Industry catalogs — one starter set per vertical so each module
--    opens with something to act on.
-- ---------------------------------------------------------------------

-- Hotel
INSERT INTO room_types (name, base_rate, capacity, description)
SELECT v.* FROM (VALUES ('Standard',35,2,'Queen bed, city view'),('Deluxe',55,3,'King bed, balcony'),('Suite',95,4,'Living room + kitchenette'))
AS v(name, base_rate, capacity, description) WHERE NOT EXISTS (SELECT 1 FROM room_types r WHERE r.name = v.name);
INSERT INTO rooms (number, room_type_id, floor, status)
SELECT v.num, (SELECT id FROM room_types WHERE name = v.rt), v.fl, 'available'
FROM (VALUES ('101','Standard',1),('102','Standard',1),('201','Deluxe',2),('202','Deluxe',2),('301','Suite',3))
AS v(num, rt, fl) WHERE NOT EXISTS (SELECT 1 FROM rooms r WHERE r.number = v.num);

-- Restaurant
INSERT INTO menu_categories (name, sort) SELECT v.* FROM (VALUES ('Starters',1),('Mains',2),('Drinks',3))
AS v(name, sort) WHERE NOT EXISTS (SELECT 1 FROM menu_categories m WHERE m.name = v.name);
INSERT INTO menu_items (category_id, name, price, station, available)
SELECT (SELECT id FROM menu_categories WHERE name = v.cat), v.name, v.price, v.station, true
FROM (VALUES ('Starters','Spring rolls',3.50,'kitchen'),('Starters','Papaya salad',4.00,'kitchen'),
             ('Mains','Fish amok',7.50,'kitchen'),('Mains','Lok lak',8.00,'kitchen'),
             ('Mains','Fried rice',5.00,'kitchen'),('Drinks','Iced coffee',2.00,'bar'),('Drinks','Angkor beer',1.50,'bar'))
AS v(cat, name, price, station) WHERE NOT EXISTS (SELECT 1 FROM menu_items m WHERE m.name = v.name);
INSERT INTO restaurant_tables (name, seats, area, status)
SELECT v.* FROM (VALUES ('T1',2,'Indoor','available'),('T2',4,'Indoor','available'),('T3',4,'Terrace','available'),('T4',6,'Terrace','available'))
AS v(name, seats, area, status) WHERE NOT EXISTS (SELECT 1 FROM restaurant_tables t WHERE t.name = v.name);

-- Salon / Gym / Laundry / Water
INSERT INTO salon_services (name, category, duration_min, price, is_active)
SELECT v.*, true FROM (VALUES ('Haircut — ladies','Hair',45,12.00),('Haircut — men','Hair',30,7.00),
  ('Hair colour','Hair',90,35.00),('Manicure','Nails',40,10.00),('Massage 60min','Spa',60,18.00))
AS v(name, category, duration_min, price) WHERE NOT EXISTS (SELECT 1 FROM salon_services s WHERE s.name = v.name);
INSERT INTO gym_plans (name, duration_days, price, sessions_limit, is_active)
SELECT v.*, true FROM (VALUES ('Monthly unlimited',30,25.00,NULL::int),('Quarterly',90,65.00,NULL::int),('10-session pass',120,30.00,10))
AS v(name, duration_days, price, sessions_limit) WHERE NOT EXISTS (SELECT 1 FROM gym_plans g WHERE g.name = v.name);
INSERT INTO laundry_services (name, unit, price, is_active)
SELECT v.*, true FROM (VALUES ('Wash & fold','kg',1.50),('Dry clean — shirt','item',2.00),('Dry clean — suit','set',7.00),('Ironing','item',0.80))
AS v(name, unit, price) WHERE NOT EXISTS (SELECT 1 FROM laundry_services l WHERE l.name = v.name);
INSERT INTO water_products (name, price, deposit, is_active)
SELECT v.*, true FROM (VALUES ('20L bottle',2.50,5.00),('20L refill',1.50,0.00),('500ml case x24',4.00,0.00))
AS v(name, price, deposit) WHERE NOT EXISTS (SELECT 1 FROM water_products w WHERE w.name = v.name);

-- Health: pharmacy, lab
INSERT INTO pharmacy_products (name, generic_name, form, strength, unit, category, requires_rx, reorder_level, sale_price, cost_price, is_active)
SELECT v.*, true FROM (VALUES
  ('Paracetamol 500mg','Paracetamol','tablet','500mg','tablet','Analgesic',false,100, 0.10, 0.04),
  ('Amoxicillin 500mg','Amoxicillin','capsule','500mg','capsule','Antibiotic',true, 50, 0.35, 0.18),
  ('ORS sachet','Oral rehydration salts','other','','sachet','Rehydration',false,60, 0.50, 0.22),
  ('Cough syrup 100ml','Dextromethorphan','syrup','100ml','bottle','Cold & flu',false,20, 3.20, 1.60))
AS v(name, generic_name, form, strength, unit, category, requires_rx, reorder_level, sale_price, cost_price)
WHERE NOT EXISTS (SELECT 1 FROM pharmacy_products p WHERE p.name = v.name);
INSERT INTO lab_tests (name, code, category, specimen_type, unit, ref_low, ref_high, price, tat_hours, is_active)
SELECT v.*, true FROM (VALUES
  ('Haemoglobin','HGB','Haematology','Blood','g/dL',12.0,16.0, 6.00, 4),
  ('Fasting glucose','GLU-F','Biochemistry','Serum','mmol/L',3.9,5.5, 5.00, 4),
  ('Creatinine','CREA','Biochemistry','Serum','mg/dL',0.6,1.2, 7.00, 6),
  ('Dengue NS1','DEN','Serology','Serum','',NULL::numeric,NULL::numeric,12.00,24))
AS v(name, code, category, specimen_type, unit, ref_low, ref_high, price, tat_hours)
WHERE NOT EXISTS (SELECT 1 FROM lab_tests t WHERE t.code = v.code);

-- Retail POS
INSERT INTO retail_products (name, sku, barcode, category, price, cost, tax_rate, quantity, reorder_level, is_active)
SELECT v.*, true FROM (VALUES
  ('Coca-Cola 330ml','R-001','8850001','Drinks',0.75,0.45,10, 120, 24),
  ('Instant noodles','R-002','8850002','Food',0.40,0.22,10, 200, 40),
  ('Shampoo 400ml','R-003','8850003','Personal care',3.50,2.10,10, 35, 10),
  ('AA batteries x4','R-004','8850004','Household',2.20,1.20,10, 48, 12))
AS v(name, sku, barcode, category, price, cost, tax_rate, quantity, reorder_level)
WHERE NOT EXISTS (SELECT 1 FROM retail_products p WHERE p.sku = v.sku);

-- Finance verticals
INSERT INTO loan_products (name, interest_rate, interest_method, default_term_months, fee_flat, fee_percent, currency, is_active)
SELECT v.*, true FROM (VALUES ('Micro business 12m',18.0,'declining',12,10.00,1.0,'USD'),
  ('Agriculture 6m',15.0,'flat',6,5.00,0.5,'USD'),('Personal 24m',22.0,'declining',24,15.00,1.5,'USD'))
AS v(name, interest_rate, interest_method, default_term_months, fee_flat, fee_percent, currency)
WHERE NOT EXISTS (SELECT 1 FROM loan_products l WHERE l.name = v.name);
INSERT INTO gold_rates (karat, buy_per_gram, sell_per_gram)
SELECT v.* FROM (VALUES ('24K',82.00,86.00),('22K',75.00,79.00),('18K',61.00,65.00))
AS v(karat, buy_per_gram, sell_per_gram) WHERE NOT EXISTS (SELECT 1 FROM gold_rates g WHERE g.karat = v.karat);
INSERT INTO fx_rates (currency_code, buy_rate, sell_rate, base_code)
SELECT v.* FROM (VALUES ('KHR',4080.0,4120.0,'USD'),('THB',35.2,36.0,'USD'),('VND',25300.0,25600.0,'USD'))
AS v(currency_code, buy_rate, sell_rate, base_code) WHERE NOT EXISTS (SELECT 1 FROM fx_rates f WHERE f.currency_code = v.currency_code);
INSERT INTO insurance_products (name, type, provider, default_commission_pct, is_active)
SELECT v.*, true FROM (VALUES ('Motor comprehensive','motor','Forte',12.0),('Health family','health','Infinity',15.0),
  ('Travel single trip','travel','Asia Insurance',20.0))
AS v(name, type, provider, default_commission_pct) WHERE NOT EXISTS (SELECT 1 FROM insurance_products i WHERE i.name = v.name);

-- Property / rental / fleet
INSERT INTO rental_units (name, building, type, bedrooms, bathrooms, size_sqm, rent_amount, deposit_amount, currency, status)
SELECT v.*, 'USD','available' FROM (VALUES ('A-101','Block A','apartment',2,1,65,350,700),
  ('A-102','Block A','apartment',1,1,45,250,500),('B-201','Block B','shop',0,1,80,600,1200))
AS v(name, building, type, bedrooms, bathrooms, size_sqm, rent_amount, deposit_amount)
WHERE NOT EXISTS (SELECT 1 FROM rental_units u WHERE u.name = v.name);
INSERT INTO vehicles (name, plate, type, make, model, year, status, odometer, fuel_type)
SELECT v.name, v.plate, v.type, v.make, v.model, v.year, 'active', v.odo, v.fuel
FROM (VALUES ('Delivery truck 1','2AB-1234','truck','Hino','300',2019, 84000,'diesel'),
  ('Van 1','2AC-5678','van','Toyota','HiAce',2021, 42000,'diesel'),('Moto 1','1BC-4321','motorcycle','Honda','Dream',2022, 12000,'gasoline'))
AS v(name, plate, type, make, model, year, odo, fuel)
WHERE NOT EXISTS (SELECT 1 FROM vehicles x WHERE x.plate = v.plate);

-- Leisure / services
INSERT INTO gaming_stations (name, type, hourly_rate, status)
SELECT v.*, 'available' FROM (VALUES ('PC-01','pc',1.00),('PC-02','pc',1.00),('PS5-01','console',2.50),('Billiard-1','billiard',3.00))
AS v(name, type, hourly_rate) WHERE NOT EXISTS (SELECT 1 FROM gaming_stations g WHERE g.name = v.name);
INSERT INTO parking_zones (name, capacity, hourly_rate, flat_rate)
SELECT v.* FROM (VALUES ('Ground floor',60,0.50,3.00),('Basement',40,0.40,2.50),('Moto area',120,0.25,1.00))
AS v(name, capacity, hourly_rate, flat_rate) WHERE NOT EXISTS (SELECT 1 FROM parking_zones z WHERE z.name = v.name);
INSERT INTO tour_packages (name, days, nights, destinations, base_price, cost_estimate, is_active)
SELECT v.*, true FROM (VALUES ('Angkor 3D2N',3,2,'Siem Reap',180.00,110.00),
  ('Coastal 4D3N',4,3,'Kep, Kampot',260.00,160.00),('City day tour',1,0,'Phnom Penh',35.00,18.00))
AS v(name, days, nights, destinations, base_price, cost_estimate)
WHERE NOT EXISTS (SELECT 1 FROM tour_packages t WHERE t.name = v.name);
INSERT INTO funeral_packages (name, price, description, is_active)
SELECT v.*, true FROM (VALUES ('Standard service',850.00,'Casket, transport, 3-day ceremony'),
  ('Premium service',1800.00,'Full arrangement with venue'),('Cremation only',400.00,'Basic cremation'))
AS v(name, price, description) WHERE NOT EXISTS (SELECT 1 FROM funeral_packages f WHERE f.name = v.name);

-- Agriculture + school
INSERT INTO farm_plots (name, area_hectares, location, soil_type)
SELECT v.* FROM (VALUES ('North field',4.5,'Battambang','Clay loam'),('River plot',2.0,'Battambang','Alluvial'),('Hill plot',3.2,'Pursat','Sandy loam'))
AS v(name, area_hectares, location, soil_type) WHERE NOT EXISTS (SELECT 1 FROM farm_plots p WHERE p.name = v.name);
INSERT INTO academic_programs (name, code, level) SELECT v.* FROM (VALUES ('General English','ENG','Certificate'),('Computer Basics','ICT','Certificate'))
AS v(name, code, level) WHERE NOT EXISTS (SELECT 1 FROM academic_programs p WHERE p.code = v.code);
INSERT INTO academic_terms (name, type, start_date, end_date, is_current)
SELECT v.name, v.type, v.sd::date, v.ed::date, v.cur FROM (VALUES
  ('Term 1 2026','term','2026-01-06','2026-04-03', true),('Term 2 2026','term','2026-04-20','2026-07-17', false))
AS v(name, type, sd, ed, cur) WHERE NOT EXISTS (SELECT 1 FROM academic_terms t WHERE t.name = v.name);
INSERT INTO subjects (name, code, credit_hours, program_id)
SELECT v.name, v.code, v.ch, (SELECT id FROM academic_programs WHERE code = v.prog)
FROM (VALUES ('English Level 1','ENG101',3,'ENG'),('English Level 2','ENG102',3,'ENG'),('Intro to Computers','ICT101',3,'ICT'))
AS v(name, code, ch, prog) WHERE NOT EXISTS (SELECT 1 FROM subjects s WHERE s.code = v.code);

-- ---- wave-2 Cambodia verticals ----
INSERT INTO dev_projects (name, location, phase, total_units)
SELECT v.* FROM (VALUES ('Borey Sunrise','Sen Sok, Phnom Penh','Phase 1',24),('Riverside Condo','Chroy Changvar','Tower A',40))
AS v(name, location, phase, total_units) WHERE NOT EXISTS (SELECT 1 FROM dev_projects p WHERE p.name = v.name);
INSERT INTO dev_units (project_id, unit_no, unit_type, block, land_area, floor_area, list_price, status)
SELECT (SELECT id FROM dev_projects WHERE name = v.proj), v.unit_no, v.ut, v.blk, v.la, v.fa, v.price, 'available'
FROM (VALUES ('Borey Sunrise','A-01','villa','A',120,180, 95000),('Borey Sunrise','A-02','villa','A',120,180, 95000),
             ('Borey Sunrise','B-05','shophouse','B',80,160, 78000),('Riverside Condo','T-0903','condo','A',0,62, 68000))
AS v(proj, unit_no, ut, blk, la, fa, price) WHERE NOT EXISTS (SELECT 1 FROM dev_units u WHERE u.unit_no = v.unit_no);

INSERT INTO fuel_tanks (name, fuel_type, capacity, current_volume)
SELECT v.* FROM (VALUES ('Tank 1 — Gasoline','gasoline',20000,14200),('Tank 2 — Diesel','diesel',20000, 9800),('Tank 3 — Premium','premium',10000, 2100))
AS v(name, fuel_type, capacity, current_volume) WHERE NOT EXISTS (SELECT 1 FROM fuel_tanks t WHERE t.name = v.name);
INSERT INTO fuel_pumps (name, tank_id, last_reading, is_active)
SELECT v.name, (SELECT id FROM fuel_tanks WHERE name = v.tank), v.reading, true
FROM (VALUES ('Pump 1 / Nozzle A','Tank 1 — Gasoline',158420),('Pump 1 / Nozzle B','Tank 2 — Diesel',203115),
             ('Pump 2 / Nozzle A','Tank 1 — Gasoline', 98750),('Pump 2 / Nozzle B','Tank 3 — Premium', 41200))
AS v(name, tank, reading) WHERE NOT EXISTS (SELECT 1 FROM fuel_pumps p WHERE p.name = v.name);

INSERT INTO device_units (model, brand, serial_no, color, storage, cost_price, sale_price, status, warranty_months)
SELECT v.model, v.brand, v.serial_no, v.color, v.storage, v.cost_price, v.sale_price, 'in_stock', v.wm FROM (VALUES
  ('Galaxy A15','Samsung','356789104512301','Blue','128GB',145.00,189.00, 12),
  ('Galaxy A15','Samsung','356789104512302','Black','128GB',145.00,189.00, 12),
  ('Redmi Note 13','Xiaomi','869123456789011','Green','256GB',168.00,215.00, 12),
  ('iPhone 13','Apple','353912109876541','Midnight','128GB',430.00,529.00,  6))
AS v(model, brand, serial_no, color, storage, cost_price, sale_price, wm)
WHERE NOT EXISTS (SELECT 1 FROM device_units d WHERE d.serial_no = v.serial_no);

INSERT INTO manpower_sites (name, client_name, address, bill_rate, pay_rate, guards_required, is_active)
SELECT v.*, true FROM (VALUES ('Riverside Hotel — night','Riverside Hotel','Sisowath Quay',22.00,14.00,3),
  ('Angkor Trading warehouse','Angkor Trading Co.','St 271',18.00,11.50,2),('Bayon Garments factory','Bayon Garments','Kandal',20.00,13.00,4))
AS v(name, client_name, address, bill_rate, pay_rate, guards_required)
WHERE NOT EXISTS (SELECT 1 FROM manpower_sites s WHERE s.name = v.name);

INSERT INTO ktv_rooms (name, room_type, hourly_rate, capacity, status)
SELECT v.*, 'available' FROM (VALUES ('Room 1','small',8.00,6),('Room 2','small',8.00,6),('Room 5','medium',14.00,12),('VIP 1','vip',25.00,20))
AS v(name, room_type, hourly_rate, capacity) WHERE NOT EXISTS (SELECT 1 FROM ktv_rooms r WHERE r.name = v.name);

INSERT INTO garment_styles (style_no, name, buyer, smv, cmt_price)
SELECT v.* FROM (VALUES ('ST-2201','Men''s polo shirt','H&M',14.5,1.85),('ST-2202','Ladies blouse','Zara',18.0,2.40),('ST-2203','Cargo shorts','Uniqlo',16.2,2.10))
AS v(style_no, name, buyer, smv, cmt_price) WHERE NOT EXISTS (SELECT 1 FROM garment_styles s WHERE s.style_no = v.style_no);
INSERT INTO garment_lines (name, worker_count, is_active)
SELECT v.*, true FROM (VALUES ('Line A',42),('Line B',38),('Line C',45))
AS v(name, worker_count) WHERE NOT EXISTS (SELECT 1 FROM garment_lines l WHERE l.name = v.name);

-- ---- library ----
-- The circulation policy is created by verticals/library.sql, but a reset
-- clears data — so restore a working default here too rather than leave the
-- module with no policy row to read.
INSERT INTO library_policy (id) VALUES (true) ON CONFLICT (id) DO NOTHING;

INSERT INTO library_items (title, authors, isbn, publisher, published_year, language, call_number, category)
SELECT v.* FROM (VALUES
  ('A History of Cambodia','David Chandler','978-0813343631','Westview Press',2007,'en','959.6 CHA','History'),
  ('Khmer Grammar Basics','Sok Panha','978-9924000011','Angkor Press',2019,'km','495.93 SOK','Language'),
  ('Introduction to Accounting','Mary Wells','978-0134727790','Pearson',2018,'en','657 WEL','Business'),
  ('Clean Code','Robert C. Martin','978-0132350884','Prentice Hall',2008,'en','005.1 MAR','Computing'),
  ('Cambodian Folk Tales','Chey Sophea',NULL,'Reyum',2015,'km','398.2 CHE','Fiction'),
  ('Public Health in Southeast Asia','Nguyen Tran','978-9811234567','Springer',2021,'en','362.1 NGU','Health')
) AS v(title, authors, isbn, publisher, published_year, language, call_number, category)
WHERE NOT EXISTS (SELECT 1 FROM library_items x WHERE x.title = v.title);

-- Copies: two titles get several so holds and queues can be exercised.
INSERT INTO library_copies (item_id, accession_no, shelf, cost, status)
SELECT (SELECT id FROM library_items WHERE title = v.t), v.acc, v.shelf, v.cost, 'available'
FROM (VALUES
  ('A History of Cambodia','ACC-0001','A1',18.00),
  ('A History of Cambodia','ACC-0002','A1',18.00),
  ('Khmer Grammar Basics','ACC-0003','A2', 9.00),
  ('Khmer Grammar Basics','ACC-0004','A2', 9.00),
  ('Khmer Grammar Basics','ACC-0005','A2', 9.00),
  ('Introduction to Accounting','ACC-0006','B1',32.00),
  ('Clean Code','ACC-0007','B2',28.00),
  ('Clean Code','ACC-0008','B2',28.00),
  ('Cambodian Folk Tales','ACC-0009','C1', 7.50),
  ('Public Health in Southeast Asia','ACC-0010','C2',41.00)
) AS v(t, acc, shelf, cost)
WHERE NOT EXISTS (SELECT 1 FROM library_copies x WHERE x.accession_no = v.acc);

INSERT INTO library_members (member_no, name, member_type, phone, status)
SELECT v.* FROM (VALUES
  ('M-0001','Sokha Chan','staff','012 345 678','active'),
  ('M-0002','Dara Prak','staff','012 111 222','active'),
  ('M-0003','Srey Neang','student','012 333 444','active'),
  ('M-0004','Vireak Sok','student','012 555 666','active'),
  ('M-0005','Chanlina Meas','student','012 777 888','active'),
  ('M-0006','Rithy Chea','public','012 999 000','suspended')
) AS v(member_no, name, member_type, phone, status)
WHERE NOT EXISTS (SELECT 1 FROM library_members x WHERE x.member_no = v.member_no);

-- ---- consignment (a publisher whose stock we hold but do not own) ----
INSERT INTO vendors (name, email, phone, address, tax_id, lead_time_days, is_preferred)
SELECT 'Angkor Book Distributors','sales@angkorbooks.test','023 666 666','St 310, Phnom Penh','K001-6666', 14, false
WHERE NOT EXISTS (SELECT 1 FROM vendors x WHERE x.name = 'Angkor Book Distributors');

INSERT INTO stock_items (sku, name, category, unit, cost_price, sale_price, quantity, reorder_level, location,
                         is_consigned, consignor_vendor_id, isbn, author, publisher)
SELECT v.sku, v.name, 'Books', 'copy', v.cost, v.price, v.qty, 5, 'Main Warehouse',
       true, (SELECT id FROM vendors WHERE name = 'Angkor Book Distributors'), v.isbn, v.author, v.publisher
FROM (VALUES
  ('BK-0001','A History of Cambodia (retail)', 12.00, 19.50, 20,'978-0813343631','David Chandler','Westview Press'),
  ('BK-0002','Khmer Grammar Basics (retail)',   5.50,  9.00, 35,'978-9924000011','Sok Panha','Angkor Press'),
  ('BK-0003','Clean Code (retail)',            19.00, 29.00, 12,'978-0132350884','Robert C. Martin','Prentice Hall')
) AS v(sku, name, cost, price, qty, isbn, author, publisher)
WHERE NOT EXISTS (SELECT 1 FROM stock_items x WHERE x.sku = v.sku);

-- ---- research institute ----
INSERT INTO research_equipment (name, code, location, charge_rate, charge_unit)
SELECT v.* FROM (VALUES
  ('Mass Spectrometer','EQ-MS-01','Lab 2', 25.00,'hour'),
  ('High-speed Centrifuge','EQ-CF-01','Lab 1', 8.00,'hour'),
  ('Field Vehicle (4WD)','EQ-VH-01','Motor pool', 45.00,'day'),
  ('PCR Thermocycler','EQ-PCR-01','Lab 1', 0.00,'hour')
) AS v(name, code, location, charge_rate, charge_unit)
WHERE NOT EXISTS (SELECT 1 FROM research_equipment x WHERE x.name = v.name);

-- One protocol is deliberately close to expiry and one has already lapsed,
-- so the ethics warnings have something real to show.
INSERT INTO ethics_approvals (protocol_no, title, committee, submitted_date, approved_date, expires_date, status)
SELECT v.protocol_no, v.title, v.committee, v.sd::date, v.ad::date, v.ed::date, v.status FROM (VALUES
  ('IRB-2025-014','Rural water quality and household health','National Ethics Committee','2025-01-10','2025-02-20','2026-02-19','approved'),
  ('IRB-2026-003','Adolescent nutrition survey','National Ethics Committee','2026-01-05','2026-02-10','2026-09-30','approved'),
  ('IRB-2026-011','Urban air quality monitoring','University Review Board','2026-06-01',NULL,NULL,'submitted')
) AS v(protocol_no, title, committee, sd, ad, ed, status)
WHERE NOT EXISTS (SELECT 1 FROM ethics_approvals x WHERE x.protocol_no = v.protocol_no);

INSERT INTO research_outputs (title, output_type, authors, venue, publication_date, status, citation_count, open_access)
SELECT v.title, v.output_type, v.authors, v.venue, v.pd::date, v.status, v.cites, v.oa FROM (VALUES
  ('Arsenic levels in Mekong delta wells','journal_article','Chan S., Tran N.','Environmental Health Perspectives','2025-11-14','published',12,true),
  ('Adolescent nutrition in peri-urban Phnom Penh','conference','Meas C., Sok V.','SEA Public Health Congress','2026-03-02','published',3,false),
  ('Household water treatment dataset 2025','dataset','Chan S.','Zenodo','2026-01-20','published',1,true),
  ('Air quality sensor calibration methods','journal_article','Prak D.','Atmospheric Measurement Techniques',NULL,'under_review',0,false)
) AS v(title, output_type, authors, venue, pd, status, cites, oa)
WHERE NOT EXISTS (SELECT 1 FROM research_outputs x WHERE x.title = v.title);

-- ---- LPG / gas cylinders ----
INSERT INTO lpg_products (name, size_kg, gas_price, cylinder_deposit, cylinder_value, test_interval_months)
SELECT v.* FROM (VALUES
  ('12.5kg Household',12.5,14.00,25.00,45.00,60),
  ('15kg Household',15.0,17.00,28.00,52.00,60),
  ('45kg Commercial',45.0,48.00,60.00,140.00,60)
) AS v(name, size_kg, gas_price, cylinder_deposit, cylinder_value, test_interval_months)
WHERE NOT EXISTS (SELECT 1 FROM lpg_products x WHERE x.name = v.name);

-- Twelve cylinders. Two are deliberately past their retest date so the
-- safety block has something real to refuse.
INSERT INTO lpg_cylinders (serial_no, product_id, state, location, last_test_date, next_test_date)
SELECT v.serial, (SELECT id FROM lpg_products WHERE name = v.prod), v.state, 'depot', v.lt::date, v.nt::date
FROM (VALUES
  ('LPG-00001','12.5kg Household','full','2023-03-01','2028-03-01'),
  ('LPG-00002','12.5kg Household','full','2023-03-01','2028-03-01'),
  ('LPG-00003','12.5kg Household','full','2023-03-01','2028-03-01'),
  ('LPG-00004','12.5kg Household','empty','2023-03-01','2028-03-01'),
  ('LPG-00005','12.5kg Household','empty','2021-01-15','2026-01-14'),
  ('LPG-00006','15kg Household','full','2024-06-10','2029-06-10'),
  ('LPG-00007','15kg Household','full','2024-06-10','2029-06-10'),
  ('LPG-00008','15kg Household','empty','2024-06-10','2029-06-10'),
  ('LPG-00009','45kg Commercial','full','2022-11-20','2027-11-20'),
  ('LPG-00010','45kg Commercial','full','2022-11-20','2027-11-20'),
  ('LPG-00011','45kg Commercial','empty','2020-08-05','2025-08-04'),
  ('LPG-00012','45kg Commercial','full','2024-02-01','2029-02-01')
) AS v(serial, prod, state, lt, nt)
WHERE NOT EXISTS (SELECT 1 FROM lpg_cylinders x WHERE x.serial_no = v.serial);

-- ---- co-working ----
INSERT INTO cowork_plans (name, plan_type, monthly_price, day_pass_price, included_hours, overage_rate, deposit)
SELECT v.* FROM (VALUES
  ('Hot Desk','hot_desk', 60.00, 6.00,  4, 5.00,  60.00),
  ('Dedicated Desk','dedicated_desk',120.00, 0.00, 10, 4.00, 120.00),
  ('Private Office (4)','private_office',450.00, 0.00, 25, 3.00, 450.00),
  ('Virtual Office','virtual', 25.00, 0.00,  0, 8.00,   0.00)
) AS v(name, plan_type, monthly_price, day_pass_price, included_hours, overage_rate, deposit)
WHERE NOT EXISTS (SELECT 1 FROM cowork_plans x WHERE x.name = v.name);

INSERT INTO cowork_spaces (name, space_type, capacity, floor, hourly_rate)
SELECT v.* FROM (VALUES
  ('Desk 01','desk',1,'2F', 0.00), ('Desk 02','desk',1,'2F', 0.00),
  ('Desk 03','desk',1,'2F', 0.00), ('Desk 04','desk',1,'2F', 0.00),
  ('Desk 05','desk',1,'3F', 0.00), ('Desk 06','desk',1,'3F', 0.00),
  ('Meeting Room A','meeting_room',8,'2F', 9.00),
  ('Meeting Room B','meeting_room',4,'3F', 6.00),
  ('Phone Booth 1','phone_booth',1,'2F', 3.00),
  ('Office 301','office',4,'3F', 0.00)
) AS v(name, space_type, capacity, floor, hourly_rate)
WHERE NOT EXISTS (SELECT 1 FROM cowork_spaces x WHERE x.name = v.name);

INSERT INTO cowork_members (member_no, name, company_name, phone, plan_id, desk_space_id, status)
SELECT v.no, v.name, v.co, v.phone,
       (SELECT id FROM cowork_plans WHERE name = v.plan),
       (SELECT id FROM cowork_spaces WHERE name = v.desk),
       'active'
FROM (VALUES
  ('CW-001','Sopheak Ly','Khmer Devs','012 111 333','Dedicated Desk','Desk 01'),
  ('CW-002','Malis Ung','Freelance','012 222 444','Hot Desk',NULL),
  ('CW-003','Panha Tep','Angkor Analytics','012 333 555','Dedicated Desk','Desk 02'),
  ('CW-004','Chantrea Yos','Studio Nine','012 444 666','Hot Desk',NULL)
) AS v(no, name, co, phone, plan, desk)
WHERE NOT EXISTS (SELECT 1 FROM cowork_members x WHERE x.member_no = v.no);

-- ---- commission rules ----
-- A general rule plus two specific ones, so the most-specific-wins order and
-- the tier bands both have something to demonstrate.
INSERT INTO commission_rules (name, role, source_module, basis, rate, min_value, max_value, priority)
SELECT v.* FROM (VALUES
  ('Everyone — 3% baseline', NULL, 'any', 'percent', 3.0, 0, NULL::numeric, 0),
  ('Stylists — 10% of the service', 'Stylist', 'salon', 'percent', 10.0, 0, NULL::numeric, 1),
  ('Insurance agents — 20% of agency commission', 'Insurance Agent', 'insurance', 'percent', 20.0, 0, NULL::numeric, 1),
  ('Brokers — small deals 25%', 'Broker', 'brokerage', 'percent', 25.0, 0, 1000, 2),
  ('Brokers — large deals 35%', 'Broker', 'brokerage', 'percent', 35.0, 1000, NULL::numeric, 2),
  ('Mechanics — 15% of labour', 'Mechanic', 'workshop', 'percent', 15.0, 0, NULL::numeric, 1)
) AS v(name, role, source_module, basis, rate, min_value, max_value, priority)
WHERE NOT EXISTS (SELECT 1 FROM commission_rules x WHERE x.name = v.name);

-- ---- fixed assets, classified for GDT tax depreciation ----
-- One asset per GDT class, so the annual return has something to allow and
-- the difference between book and tax depreciation is visible on day one.
INSERT INTO assets (name, category, price, purchase_date, status, condition,
                    useful_life_months, salvage_value, depreciation_start,
                    tax_class, tax_depreciation_start)
SELECT v.* FROM (VALUES
  ('Warehouse building, Sen Sok','Building',120000::numeric,'2023-01-15'::date,'available','good',
     240,0::numeric,'2023-01-15'::date,1,'2023-01-15'::date),
  ('Office server and network rack','IT',9500::numeric,'2024-03-01'::date,'available','good',
     60,500::numeric,'2024-03-01'::date,2,'2024-03-01'::date),
  ('Accounting software licence','IT',4200::numeric,'2024-07-01'::date,'available','good',
     36,0::numeric,'2024-07-01'::date,2,'2024-07-01'::date),
  ('Delivery truck (Isuzu)','Vehicle',28000::numeric,'2024-05-20'::date,'available','good',
     84,3000::numeric,'2024-05-20'::date,3,'2024-05-20'::date),
  ('Office furniture, first floor','Furniture',6800::numeric,'2023-09-10'::date,'available','good',
     96,0::numeric,'2023-09-10'::date,3,'2023-09-10'::date),
  ('Workshop compressor and tooling','Equipment',7400::numeric,'2024-02-14'::date,'available','good',
     120,400::numeric,'2024-02-14'::date,4,'2024-02-14'::date)
) AS v(name, category, price, purchase_date, status, condition,
       useful_life_months, salvage_value, depreciation_start,
       tax_class, tax_depreciation_start)
WHERE EXISTS (SELECT 1 FROM tax_asset_classes)
  AND NOT EXISTS (SELECT 1 FROM assets x WHERE x.name = v.name);

-- ---------------------------------------------------------------------
-- Done. Next: Accounting -> Accounts -> "Install Standard Accounts",
-- then follow docs/Testing-Kareya.md.
-- ---------------------------------------------------------------------
