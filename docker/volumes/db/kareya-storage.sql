-- Kareya Silo — storage buckets + RLS policies.
--
-- On a self-hosted stack the storage schema (storage.buckets / storage.objects)
-- is created by the storage service at runtime, AFTER Postgres init. So the
-- main schema guards its bucket INSERT and RLS.sql guards its storage.objects
-- policies (both no-op when storage is absent); this file is applied once by
-- the storage-init one-shot container after the storage service is healthy,
-- so a fresh install is fully featured. Idempotent.
--
-- Buckets:
--   kb-sources  — private; AI source documents the owner feeds the assistant.
--   silo-media  — private; general media (logos, attachments, avatars).
-- Access is gated to employees of this silo via the storage.objects policies
-- below, which mirror supabase/setup/schema/RLS.sql exactly.

INSERT INTO storage.buckets (id, name, public) VALUES ('kb-sources', 'kb-sources', false) ON CONFLICT (id) DO NOTHING;
INSERT INTO storage.buckets (id, name, public) VALUES ('silo-media', 'silo-media', false) ON CONFLICT (id) DO NOTHING;

-- kb-sources: employees read; Support/Manager curate (write/update/delete).
DROP POLICY IF EXISTS "Employees read kb-sources" ON storage.objects;
CREATE POLICY "Employees read kb-sources" ON storage.objects FOR SELECT TO authenticated USING (bucket_id = 'kb-sources' AND is_employee());
DROP POLICY IF EXISTS "Owners/curators write kb-sources" ON storage.objects;
CREATE POLICY "Owners/curators write kb-sources" ON storage.objects FOR INSERT TO authenticated WITH CHECK (bucket_id = 'kb-sources' AND has_any_role(ARRAY['Support','Manager']));
DROP POLICY IF EXISTS "Owners/curators update kb-sources" ON storage.objects;
CREATE POLICY "Owners/curators update kb-sources" ON storage.objects FOR UPDATE TO authenticated USING (bucket_id = 'kb-sources' AND has_any_role(ARRAY['Support','Manager'])) WITH CHECK (bucket_id = 'kb-sources' AND has_any_role(ARRAY['Support','Manager']));
DROP POLICY IF EXISTS "Owners/curators delete kb-sources" ON storage.objects;
CREATE POLICY "Owners/curators delete kb-sources" ON storage.objects FOR DELETE TO authenticated USING (bucket_id = 'kb-sources' AND has_any_role(ARRAY['Support','Manager']));

-- silo-media: any employee of this silo may read/write.
DROP POLICY IF EXISTS "Employees read silo-media" ON storage.objects;
CREATE POLICY "Employees read silo-media" ON storage.objects FOR SELECT TO authenticated USING (bucket_id = 'silo-media' AND is_employee());
DROP POLICY IF EXISTS "Employees write silo-media" ON storage.objects;
CREATE POLICY "Employees write silo-media" ON storage.objects FOR INSERT TO authenticated WITH CHECK (bucket_id = 'silo-media' AND is_employee());
DROP POLICY IF EXISTS "Employees update silo-media" ON storage.objects;
CREATE POLICY "Employees update silo-media" ON storage.objects FOR UPDATE TO authenticated USING (bucket_id = 'silo-media' AND is_employee()) WITH CHECK (bucket_id = 'silo-media' AND is_employee());
DROP POLICY IF EXISTS "Employees delete silo-media" ON storage.objects;
CREATE POLICY "Employees delete silo-media" ON storage.objects FOR DELETE TO authenticated USING (bucket_id = 'silo-media' AND is_employee());
