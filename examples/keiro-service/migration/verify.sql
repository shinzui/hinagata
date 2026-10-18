DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.keiro_reference_data WHERE code = 'alpha') THEN
    RAISE EXCEPTION 'shared reference fixture is missing';
  END IF;
END $$;
