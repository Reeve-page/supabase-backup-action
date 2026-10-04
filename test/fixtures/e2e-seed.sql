-- Seeds a local Supabase database for the end-to-end run in CI.
INSERT INTO auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
SELECT '00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated',
       'user' || g || '@example.com', 'not-a-real-hash', now(), now(), now()
FROM generate_series(1, 3) g;

INSERT INTO storage.buckets (id, name, public) VALUES ('avatars', 'avatars', false);

CREATE TABLE public.orders (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id uuid REFERENCES auth.users (id),
  total numeric NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.orders ENABLE ROW LEVEL SECURITY;
CREATE POLICY "own orders" ON public.orders FOR SELECT TO authenticated USING (auth.uid() = user_id);
INSERT INTO public.orders (user_id, total)
SELECT (SELECT id FROM auth.users ORDER BY email LIMIT 1), g FROM generate_series(1, 300) g;

CREATE TABLE public.notes (id int PRIMARY KEY, body text);
INSERT INTO public.notes VALUES (1, E'line one\nline two'), (2, E'back\\slash'), (3, NULL);

CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA pg_catalog;
GRANT USAGE ON SCHEMA cron TO postgres;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA cron TO postgres;
SELECT cron.schedule('e2e-noop', '17 3 * * *', 'select 1');
