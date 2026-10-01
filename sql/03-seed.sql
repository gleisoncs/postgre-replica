-- Test data: 10k customers, 1M orders
INSERT INTO countries VALUES ('BR','Brazil'), ('US','United States'), ('PT','Portugal'), ('AR','Argentina');

INSERT INTO customers (id, name, country_code)
SELECT i,
       'Customer ' || i,
       (ARRAY['BR','US','PT','AR'])[1 + i % 4]
FROM generate_series(1, 10000) AS i;

INSERT INTO orders (customer_id, total, created_at)
SELECT 1 + (random() * 9999)::int,
       round((random() * 1000)::numeric, 2),
       now() - random() * interval '365 days'
FROM generate_series(1, 1000000);

ANALYZE;
