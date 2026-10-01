-- Sample schema: customers/orders distributed by customer, countries replicated
CREATE TABLE countries (
    code text PRIMARY KEY,
    name text NOT NULL
);

CREATE TABLE customers (
    id           bigint PRIMARY KEY,
    name         text   NOT NULL,
    country_code text   NOT NULL
);

-- the shard key (customer_id) must be part of the PK
CREATE TABLE orders (
    id          bigserial,
    customer_id bigint      NOT NULL,
    total       numeric(12,2) NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (customer_id, id)
);

SELECT create_reference_table('countries');
-- explicit 32 shards (does not rely on the citus.shard_count default)
SELECT create_distributed_table('customers', 'id', shard_count => 32);
-- orders inherits the 32 shards from customers via colocation (Citus does not allow shard_count together with colocate_with)
SELECT create_distributed_table('orders', 'customer_id', colocate_with => 'customers');
