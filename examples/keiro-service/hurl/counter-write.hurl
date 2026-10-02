POST {{base_url}}/counters/alpha/add
HTTP 201
[Asserts]
header "Content-Type" contains "application/json"
jsonpath "$.appended" == true

GET {{base_url}}/counters/alpha
HTTP 200
[Asserts]
header "Content-Type" contains "application/json"
jsonpath "$.total" == 1

GET {{base_url}}/counters/INVALID
HTTP 400
[Asserts]
header "Content-Type" contains "application/json"
jsonpath "$.error" == "invalid_counter_id"
