INSERT INTO public.keiro_reference_data (id, code, label)
VALUES (1, 'alpha', 'Alpha'), (2, 'beta', 'Beta');

SELECT setval(pg_get_serial_sequence('public.keiro_reference_data', 'id'), 2, true);
