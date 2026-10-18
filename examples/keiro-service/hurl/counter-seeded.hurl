GET {{base_url}}/counters/seeded
HTTP 200
[Asserts]
header "Content-Type" contains "application/json"
jsonpath "$.total" == {{seed_total}}
