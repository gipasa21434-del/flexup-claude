-- Behavioural tests for RLS, counters, rate limits and RPCs.
-- Run: ./scripts/test_database.sh  (plain PostgreSQL + 00_supabase_stub.sql + migrations)
\set ON_ERROR_STOP on
set client_min_messages = warning;

-- Test users (inserted as superuser, like Supabase Auth would).
insert into auth.users (id, email, raw_user_meta_data) values
  ('11111111-1111-4111-8111-111111111111', 'alice@test.dev', '{"username":"alice"}'),
  ('22222222-2222-4222-8222-222222222222', 'bob@test.dev',   '{"username":"bob"}'),
  ('33333333-3333-4333-8333-333333333333', 'eve@test.dev',   '{"username":"Bad Name!!"}');

create or replace function pg_temp.assert(cond boolean, msg text) returns void language plpgsql as $$
begin
  if not coalesce(cond, false) then raise exception 'ASSERTION FAILED: %', msg; end if;
  raise notice 'ok - %', msg;
end $$;

create or replace function pg_temp.as_user(uid text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', uid, false);
end $$;

set client_min_messages = notice;

-- Profiles created by trigger, bad usernames sanitised.
select pg_temp.assert((select count(*) from public.profiles) = 3, 'profiles auto-created for new auth users');
select pg_temp.assert((select username from public.profiles where id = '33333333-3333-4333-8333-333333333333') = 'badname',
                      'requested username sanitised ("Bad Name!!" -> badname)');
select pg_temp.assert((select count(*) from public.challenges) >= 30, 'daily challenges seeded');

-- ===== Alice publishes =====
set role authenticated;
select pg_temp.as_user('11111111-1111-4111-8111-111111111111');
insert into public.videos (id, author_id, caption, hashtags, mood, duration, storage_path, video_url, likes_count)
values ('aaaaaaaa-0000-4000-8000-000000000001', '11111111-1111-4111-8111-111111111111', 'Привет #Тест', array['Тест','bad tag!'],
        'calm', 8, '11111111-1111-4111-8111-111111111111/a1.mp4', 'https://cdn/a1.mp4', 999999);
select pg_temp.assert((select likes_count from public.videos where id = 'aaaaaaaa-0000-4000-8000-000000000001') = 0,
                      'client cannot forge counters on insert');
select pg_temp.assert((select hashtags from public.videos where id = 'aaaaaaaa-0000-4000-8000-000000000001') = array['тест'],
                      'hashtags normalised server-side, invalid ones dropped');
insert into public.videos (id, author_id, caption, duration, storage_path, video_url, visibility)
values ('aaaaaaaa-0000-4000-8000-000000000002', '11111111-1111-4111-8111-111111111111', 'секрет', 5,
        '11111111-1111-4111-8111-111111111111/a2.mp4', 'https://cdn/a2.mp4', 'only_me');

-- Cannot publish as someone else
do $$ begin
  insert into public.videos (author_id, caption, duration, storage_path, video_url)
  values ('22222222-2222-4222-8222-222222222222', 'impersonation', 5, '22222222-2222-4222-8222-222222222222/x.mp4', 'https://x');
  raise exception 'ASSERTION FAILED: impersonated insert succeeded';
exception when insufficient_privilege then raise notice 'ok - cannot publish as another user (RLS)';
end $$;

-- Cannot point storage_path into someone else's folder
do $$ begin
  insert into public.videos (author_id, caption, duration, storage_path, video_url)
  values ('11111111-1111-4111-8111-111111111111', 'x', 5, '22222222-2222-4222-8222-222222222222/x.mp4', 'https://x');
  raise exception 'ASSERTION FAILED: foreign storage path accepted';
exception when check_violation then raise notice 'ok - storage path must be in own folder';
end $$;

-- ===== Bob interacts =====
select pg_temp.as_user('22222222-2222-4222-8222-222222222222');
select pg_temp.assert((select count(*) from public.videos) = 1, 'bob sees public video only, not only_me');
insert into public.likes (user_id, video_id) values ('22222222-2222-4222-8222-222222222222', 'aaaaaaaa-0000-4000-8000-000000000001');
insert into public.comments (video_id, author_id, body) values ('aaaaaaaa-0000-4000-8000-000000000001', '22222222-2222-4222-8222-222222222222', '  Огонь  ');
insert into public.follows (follower_id, followee_id) values ('22222222-2222-4222-8222-222222222222', '11111111-1111-4111-8111-111111111111');
select pg_temp.assert((select likes_count from public.videos where id = 'aaaaaaaa-0000-4000-8000-000000000001') = 1, 'like counter incremented');
select pg_temp.assert((select comments_count from public.videos where id = 'aaaaaaaa-0000-4000-8000-000000000001') = 1, 'comment counter incremented');
select pg_temp.assert((select body from public.comments limit 1) = 'Огонь', 'comment trimmed');
select pg_temp.assert((select followers_count from public.profiles where id = '11111111-1111-4111-8111-111111111111') = 1, 'followers counter');

-- Bob cannot edit counters or Alice's profile
update public.profiles set bio = 'hacked' where id = '11111111-1111-4111-8111-111111111111';
select pg_temp.assert((select bio from public.profiles where id = '11111111-1111-4111-8111-111111111111') = '', 'cannot update foreign profile');
do $$ begin
  update public.profiles set followers_count = 1000000 where id = '22222222-2222-4222-8222-222222222222';
  raise exception 'ASSERTION FAILED: counter update allowed';
exception when insufficient_privilege then raise notice 'ok - profile counters are not user-writable';
end $$;
do $$ begin
  update public.videos set likes_count = 5000 where id = 'aaaaaaaa-0000-4000-8000-000000000001';
  raise exception 'ASSERTION FAILED: video counter update allowed';
exception when insufficient_privilege then raise notice 'ok - video counters are not user-writable';
end $$;
delete from public.videos where id = 'aaaaaaaa-0000-4000-8000-000000000001';
select pg_temp.assert(exists (select 1 from public.videos where id = 'aaaaaaaa-0000-4000-8000-000000000001'), 'cannot delete foreign video');

-- Feed RPCs
select pg_temp.assert((select count(*) from public.feed_for_you(10, null, '{}')) = 1, 'feed_for_you returns visible videos');
select pg_temp.assert((select (f ->> 'is_liked')::boolean from public.feed_for_you(10, null, '{}') f limit 1), 'feed row carries viewer like flag');
select pg_temp.assert((select f -> 'author' ->> 'username' from public.feed_for_you(10, null, '{}') f limit 1) = 'alice', 'feed row joins author');
select pg_temp.assert(not ((select f from public.feed_for_you(10, null, '{}') f limit 1) ? 'storage_path'), 'feed row hides storage_path');
select pg_temp.assert((select count(*) from public.feed_for_you(10, 'energetic', '{}')) = 0, 'MOOD FEED filters by mood');
select pg_temp.assert((select count(*) from public.feed_for_you(10, 'calm', '{}')) = 1, 'MOOD FEED keeps matching mood');
select pg_temp.assert((select count(*) from public.feed_for_you(10, null, array['тест'])) = 0, 'hidden tags filtered');
select pg_temp.assert((select count(*) from public.feed_following(10)) = 1, 'following feed');
select pg_temp.assert((select count(*) from public.search_videos('тест', 'relevance', null)) = 1, 'search videos by tag');
select pg_temp.assert((select count(*) from public.search_profiles('ali')) = 1, 'search profiles by prefix');
select pg_temp.assert((select tag from public.trending_hashtags(5) limit 1) = 'тест', 'trending hashtags');
select public.record_view('aaaaaaaa-0000-4000-8000-000000000001');
select pg_temp.assert((select views_count from public.videos where id = 'aaaaaaaa-0000-4000-8000-000000000001') = 1, 'record_view increments views');

-- DUO REACT reply → notification to original author
insert into public.videos (id, author_id, caption, duration, storage_path, video_url, reply_to)
values ('bbbbbbbb-0000-4000-8000-000000000001', '22222222-2222-4222-8222-222222222222', 'реакция', 6,
        '22222222-2222-4222-8222-222222222222/r.mp4', 'https://cdn/r.mp4', 'aaaaaaaa-0000-4000-8000-000000000001');
select pg_temp.assert((select count(*) from public.video_reactions('aaaaaaaa-0000-4000-8000-000000000001')) = 1, 'reactions listed');
do $$ begin
  insert into public.videos (author_id, caption, duration, storage_path, video_url, reply_to)
  values ('22222222-2222-4222-8222-222222222222', 'x', 6, '22222222-2222-4222-8222-222222222222/r2.mp4', 'https://x', 'aaaaaaaa-0000-4000-8000-000000000002');
  raise exception 'ASSERTION FAILED: reply to invisible video allowed';
exception when insufficient_privilege then raise notice 'ok - cannot react to a video you cannot see';
end $$;

-- Rate limit on comments (10/min)
do $$ begin
  for i in 1..15 loop
    insert into public.comments (video_id, author_id, body) values ('aaaaaaaa-0000-4000-8000-000000000001', '22222222-2222-4222-8222-222222222222', 'spam ' || i);
  end loop;
  raise exception 'ASSERTION FAILED: spam not limited';
exception when sqlstate 'P0429' then raise notice 'ok - comment spam rate-limited (%)', sqlerrm;
end $$;

-- Bob's likes are private
select pg_temp.as_user('11111111-1111-4111-8111-111111111111');
select pg_temp.assert((select count(*) from public.likes) = 0, 'alice cannot see bob''s likes');
select pg_temp.assert((select count(*) from public.notifications where kind = 'like') = 1, 'alice notified about like');
select pg_temp.assert((select count(*) from public.notifications where kind = 'react') = 1, 'alice notified about DUO REACT');
select pg_temp.assert((select count(*) from public.notifications where kind = 'follow') = 1, 'alice notified about follower');
select public.mark_notifications_read();
select pg_temp.assert(not exists (select 1 from public.notifications where not is_read), 'mark notifications read');

-- Owner can moderate comments under own video
delete from public.comments where body = 'Огонь';
select pg_temp.assert((select comments_count from public.videos where id = 'aaaaaaaa-0000-4000-8000-000000000001') = 0, 'owner deleted a comment, counter decremented (spam batch was rolled back)');

-- Blocking: Alice blocks Bob → follow removed, Bob can't see/comment/follow
insert into public.blocks (blocker_id, blocked_id) values ('11111111-1111-4111-8111-111111111111', '22222222-2222-4222-8222-222222222222');
select pg_temp.assert((select followers_count from public.profiles where id = '11111111-1111-4111-8111-111111111111') = 0, 'block removes follow');
select pg_temp.as_user('22222222-2222-4222-8222-222222222222');
select pg_temp.assert((select count(*) from public.videos where author_id = '11111111-1111-4111-8111-111111111111') = 0, 'blocked user cannot see blocker''s videos');
do $$ begin
  insert into public.follows (follower_id, followee_id) values ('22222222-2222-4222-8222-222222222222', '11111111-1111-4111-8111-111111111111');
  raise exception 'ASSERTION FAILED: follow after block allowed';
exception when insufficient_privilege then raise notice 'ok - cannot follow someone who blocked you';
end $$;

-- Reports are write-only
insert into public.reports (reporter_id, target_kind, target_id, reason) values
  ('22222222-2222-4222-8222-222222222222', 'user', '11111111-1111-4111-8111-111111111111', 'spam');
select pg_temp.assert((select count(*) from public.reports) = 0, 'reports are not readable by users');

-- Storage: own folder only
insert into storage.objects (bucket_id, name) values ('videos', '22222222-2222-4222-8222-222222222222/ok.mp4');
do $$ begin
  insert into storage.objects (bucket_id, name) values ('videos', '11111111-1111-4111-8111-111111111111/evil.mp4');
  raise exception 'ASSERTION FAILED: upload into foreign folder allowed';
exception when insufficient_privilege then raise notice 'ok - storage upload limited to own folder';
end $$;

-- Anonymous (guest) can read public content but not write
reset role;
set role anon;
select pg_temp.as_user('');
select pg_temp.assert((select count(*) from public.feed_for_you(10, null, '{}')) >= 1, 'guest can read public feed');
do $$ begin
  insert into public.likes (user_id, video_id) values ('22222222-2222-4222-8222-222222222222', 'aaaaaaaa-0000-4000-8000-000000000001');
  raise exception 'ASSERTION FAILED: anon like allowed';
exception when insufficient_privilege then raise notice 'ok - guest cannot like';
end $$;

-- Account deletion cascades
reset role;
set role authenticated;
select pg_temp.as_user('22222222-2222-4222-8222-222222222222');
reset role;
-- delete_my_account touches auth.users, which only the function owner may do.
select set_config('request.jwt.claim.sub', '22222222-2222-4222-8222-222222222222', false);
select public.delete_my_account();
select pg_temp.assert(not exists (select 1 from public.profiles where id = '22222222-2222-4222-8222-222222222222'), 'account deleted with profile');
select pg_temp.assert(not exists (select 1 from public.videos where author_id = '22222222-2222-4222-8222-222222222222'), 'deleted account videos removed');
select pg_temp.assert(not exists (select 1 from storage.objects where name like '22222222-2222-4222-8222-222222222222/%'), 'deleted account storage removed');

\echo 'ALL DATABASE TESTS PASSED'
