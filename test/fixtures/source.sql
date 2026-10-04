DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'authenticated') THEN
    CREATE ROLE authenticated NOLOGIN;
  END IF;
END
$$;

INSERT INTO auth.users (id, email) VALUES
  ('00000000-0000-0000-0000-000000000001', 'ana@example.com'),
  ('00000000-0000-0000-0000-000000000002', 'ben@example.com'),
  ('00000000-0000-0000-0000-000000000003', 'cy@example.com');

CREATE TABLE public.orders (
  id serial PRIMARY KEY,
  user_id uuid REFERENCES auth.users (id),
  total numeric NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.orders ENABLE ROW LEVEL SECURITY;
CREATE POLICY "own orders" ON public.orders FOR SELECT TO authenticated USING (true);
INSERT INTO public.orders (user_id, total)
SELECT '00000000-0000-0000-0000-000000000001', g FROM generate_series(1, 300) g;

CREATE TABLE public.notes (id int PRIMARY KEY, body text);
INSERT INTO public.notes VALUES
  (1, 'tab	here'),
  (2, E'line one\nline two'),
  (3, E'back\\slash'),
  (4, E'\\.'),
  (5, ''),
  (6, NULL);

CREATE TABLE public."Odd name" (id int);
INSERT INTO public."Odd name" VALUES (1), (2);

CREATE TABLE public.empty (id int);
