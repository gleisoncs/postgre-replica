-- Registers the coordinator and workers in the Citus cluster
SELECT citus_set_coordinator_host('coordinator', 5432);
SELECT citus_add_node('worker1', 5432);
SELECT citus_add_node('worker2', 5432);

SELECT * FROM citus_get_active_worker_nodes();
