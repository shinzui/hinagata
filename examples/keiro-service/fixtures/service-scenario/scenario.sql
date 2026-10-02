INSERT INTO public.keiro_reference_data (id, code, label)
VALUES (3, 'gamma', 'Gamma');

SELECT setval(pg_get_serial_sequence('public.keiro_reference_data', 'id'), 3, true);
