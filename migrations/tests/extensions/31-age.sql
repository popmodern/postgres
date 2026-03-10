BEGIN;
create extension if not exists age;
LOAD 'age';
SET LOCAL search_path = ag_catalog, "$user", public;

select create_graph('smoke_age_graph');

select *
from cypher('smoke_age_graph', $$
  CREATE (:Person {name: 'Ada'})
  RETURN 1
$$) as (created agtype);

select *
from cypher('smoke_age_graph', $$
  MATCH (n:Person)
  RETURN count(n)
$$) as (node_count agtype);

select drop_graph('smoke_age_graph', true);
ROLLBACK;