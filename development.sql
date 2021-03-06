
-- Silently drop everything in reverse (for development)
SET client_min_messages TO WARNING;
DROP SCHEMA "public" CASCADE;
DROP SCHEMA "random" CASCADE;
DROP SCHEMA "views" CASCADE;
SET client_min_messages TO NOTICE;
CREATE SCHEMA "public";
CREATE SCHEMA "random";
CREATE SCHEMA "views";
CREATE EXTENSION "uuid-ossp";
-- Parse tokens like tags and mentions from text
--
-- `content` - the text to parse tokens from
-- `prefix`  - the character that tokens start with e.g. # or @
CREATE FUNCTION parse_tokens(content text, prefix text)
  RETURNS text[] AS $$
    DECLARE
      regex text;
      matches text;
      subquery text;
      captures text;
      tokens text[];
    BEGIN
      regex := prefix || '(\S+)';
      matches := 'regexp_matches($1, $2, $3) as captures';
      subquery := '(SELECT ' || matches || ' ORDER BY captures) as matches';
      captures := 'array_agg(matches.captures[1])';

      EXECUTE 'SELECT ' || captures || ' FROM ' || subquery
      INTO tokens
      USING LOWER(content), regex, 'g';

      IF tokens IS NULL THEN
        tokens = '{}';
      END IF;

      RETURN tokens;
    END;
  $$ LANGUAGE plpgsql STABLE;

-------------------------------------------------------------------------------

CREATE FUNCTION random.id(table_name text, exclude uuid DEFAULT uuid_generate_v4())
  RETURNS uuid AS $$
    DECLARE
      record record;
    BEGIN
      record := random.record(table_name, exclude);
      RETURN record.id;
    END;
  $$ LANGUAGE plpgsql VOLATILE;

CREATE FUNCTION random.record(table_name text, exclude uuid DEFAULT uuid_generate_v4())
  RETURNS record AS $$
    DECLARE
      record record;
    BEGIN
      EXECUTE 'SELECT * FROM ' || table_name || ' WHERE id != $1 ORDER BY random() LIMIT 1'
      INTO record
      USING exclude;

      RETURN record;
    END;
  $$ LANGUAGE plpgsql VOLATILE;
-- ############################################################################
-- # tags
-- ############################################################################

CREATE FUNCTION delete_stale_tag()
  RETURNS trigger AS $$
    BEGIN
      DELETE FROM tags WHERE id = OLD.id;
      RETURN OLD;
    END;
  $$ LANGUAGE plpgsql;


-- ############################################################################
-- # tweets
-- ############################################################################

CREATE FUNCTION parse_mentions_from_post()
  RETURNS trigger AS $$
    BEGIN
      NEW.mentions = parse_tokens(NEW.post, '@');
      RETURN NEW;
    END;
  $$ LANGUAGE plpgsql;

CREATE FUNCTION create_new_mentions()
  RETURNS trigger AS $$
    DECLARE
      username text;
      user_id uuid;
    BEGIN
      FOREACH username IN ARRAY NEW.mentions LOOP
        BEGIN
          EXECUTE 'SELECT id FROM users WHERE username = $1'
          INTO user_id
          USING LOWER(username);

          IF user_id IS NOT NULL THEN
            INSERT INTO mentions (user_id, tweet_id)
            VALUES (user_id, NEW.id);
          END IF;
        EXCEPTION WHEN unique_violation THEN
        END;
      END LOOP;

      RETURN NEW;
    END;
  $$ LANGUAGE plpgsql;

CREATE FUNCTION delete_old_mentions()
  RETURNS trigger AS $$
    DECLARE
      mention text;
    BEGIN
      FOREACH mention IN ARRAY OLD.mentions LOOP
        IF NOT NEW.mentions @> ARRAY[mention] THEN
          DELETE FROM mentions USING users
          WHERE mentions.user_id = users.id
          AND mentions.tweet_id = NEW.id
          AND users.username = mention;
        END IF;
      END LOOP;

      RETURN NEW;
    END;
  $$ LANGUAGE plpgsql;

-------------------------------------------------------------------------------

CREATE FUNCTION parse_tags_from_post()
  RETURNS trigger AS $$
    BEGIN
      NEW.tags = parse_tokens(NEW.post, '#');
      RETURN NEW;
    END;
  $$ LANGUAGE plpgsql;

CREATE FUNCTION create_new_taggings()
  RETURNS trigger AS $$
    DECLARE
      tag text;
      user_id uuid;
    BEGIN
      FOREACH tag IN ARRAY NEW.tags LOOP
        BEGIN
          tag := LOWER(tag);
          INSERT INTO tags (name) VALUES (tag);
        EXCEPTION WHEN unique_violation THEN
        END;

        BEGIN
          EXECUTE 'SELECT id FROM tags WHERE name = $1'
          INTO user_id
          USING tag;

          INSERT INTO taggings (tag_id, tweet_id)
          VALUES (user_id, NEW.id);
        EXCEPTION WHEN unique_violation THEN
        END;
      END LOOP;

      RETURN NEW;
    END;
  $$ LANGUAGE plpgsql;

CREATE FUNCTION delete_old_taggings()
  RETURNS trigger AS $$
    DECLARE
      tag text;
    BEGIN
      FOREACH tag IN ARRAY OLD.tags LOOP
        IF NOT NEW.tags @> ARRAY[tag] THEN
          DELETE FROM taggings USING tags
          WHERE taggings.tag_id = tags.id
          AND taggings.tweet_id = NEW.id
          AND tags.name = tag;
        END IF;
      END LOOP;

      RETURN NEW;
    END;
  $$ LANGUAGE plpgsql;
CREATE FUNCTION increment_counter(table_name text, column_name text, pk_name text, pk_value uuid, step integer)
  RETURNS VOID AS $$
    DECLARE
      table_name text := quote_ident(table_name);
      column_name text := quote_ident(column_name);
      conditions text := ' WHERE ' || quote_ident(pk_name) || ' = $1';
      updates text := column_name || '=' || column_name || '+' || step;
    BEGIN
      EXECUTE 'UPDATE ' || table_name || ' SET ' || updates || conditions
      USING pk_value;
    END;
  $$ LANGUAGE plpgsql;

CREATE FUNCTION counter_cache()
  RETURNS trigger AS $$
    DECLARE
      table_name text := quote_ident(TG_ARGV[0]);
      counter_name text := quote_ident(TG_ARGV[1]);
      fk_name text := quote_ident(TG_ARGV[2]);
      pk_name text := quote_ident(TG_ARGV[3]);
      fk_changed boolean;
      fk_value uuid;
      record record;
    BEGIN
      IF TG_OP = 'UPDATE' THEN
        record := NEW;
        EXECUTE 'SELECT ($1).' || fk_name || ' != ' || '($2).' || fk_name
        INTO fk_changed
        USING OLD, NEW;
      END IF;

      IF TG_OP = 'DELETE' OR (TG_OP = 'UPDATE' AND fk_changed) THEN
        record := OLD;
        EXECUTE 'SELECT ($1).' || fk_name INTO fk_value USING record;
        PERFORM increment_counter(table_name, counter_name, pk_name, fk_value, -1);
      END IF;

      IF TG_OP = 'INSERT' OR (TG_OP = 'UPDATE' AND fk_changed) THEN
        record := NEW;
        EXECUTE 'SELECT ($1).' || fk_name INTO fk_value USING record;
        PERFORM increment_counter(table_name, counter_name, pk_name, fk_value, 1);
      END IF;

      RETURN record;
    END;
  $$ LANGUAGE plpgsql;
CREATE TABLE favorites (
  user_id   uuid NOT NULL,
  tweet_id  uuid NOT NULL,
  PRIMARY KEY(user_id, tweet_id)
);

CREATE TABLE followers (
  user_id      uuid NOT NULL,
  follower_id  uuid NOT NULL,
  created      timestamptz NOT NULL DEFAULT current_timestamp,
  PRIMARY KEY(user_id, follower_id)
);

CREATE TABLE mentions (
  user_id   uuid NOT NULL,
  tweet_id  uuid NOT NULL,
  PRIMARY KEY(user_id, tweet_id)
);

CREATE TABLE replies (
  tweet_id  uuid NOT NULL,
  reply_id  uuid NOT NULL,
  PRIMARY KEY(tweet_id, reply_id)
);

CREATE TABLE retweets (
  tweet_id    uuid NOT NULL,
  retweet_id  uuid NOT NULL,
  PRIMARY KEY(tweet_id, retweet_id)
);

CREATE TABLE tags (
  id       uuid PRIMARY KEY NOT NULL DEFAULT uuid_generate_v4(),
  name     text NOT NULL UNIQUE,
  tweets   integer NOT NULL DEFAULT 0,
  created  timestamptz NOT NULL DEFAULT current_timestamp,
  updated  timestamptz NOT NULL DEFAULT current_timestamp
);

CREATE TABLE taggings (
  tag_id    uuid NOT NULL,
  tweet_id  uuid NOT NULL,
  PRIMARY KEY(tag_id, tweet_id)
);

CREATE TABLE tweets (
  id         uuid PRIMARY KEY NOT NULL DEFAULT uuid_generate_v4(),
  user_id    uuid NOT NULL,
  post       text NOT NULL,
  favorites  integer NOT NULL DEFAULT 0,
  replies    integer NOT NULL DEFAULT 0,
  retweets   integer NOT NULL DEFAULT 0,
  mentions   text[] NOT NULL DEFAULT '{}',
  tags       text[] NOT NULL DEFAULT '{}',
  created    timestamptz NOT NULL DEFAULT current_timestamp,
  updated    timestamptz NOT NULL DEFAULT current_timestamp
);

CREATE TABLE users (
  id         uuid PRIMARY KEY NOT NULL DEFAULT uuid_generate_v4(),
  username   text NOT NULL UNIQUE,
  favorites  integer NOT NULL DEFAULT 0,
  followers  integer NOT NULL DEFAULT 0,
  following  integer NOT NULL DEFAULT 0,
  mentions   integer NOT NULL DEFAULT 0,
  tweets     integer NOT NULL DEFAULT 0,
  created    timestamptz NOT NULL DEFAULT current_timestamp,
  updated    timestamptz NOT NULL DEFAULT current_timestamp
);
CREATE VIEW views.retweets AS
  SELECT r.tweet_id, t.*
  FROM tweets AS t
  INNER JOIN retweets AS r
  ON t.id = r.retweet_id;
-- ############################################################################
-- # favorites
-- ############################################################################

ALTER TABLE favorites
  ADD CONSTRAINT user_fk FOREIGN KEY (user_id) REFERENCES users (id)
  MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;

ALTER TABLE favorites
  ADD CONSTRAINT tweet_fk FOREIGN KEY (tweet_id) REFERENCES tweets (id)
  MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


-- ############################################################################
-- # followers
-- ############################################################################

ALTER TABLE followers
  ADD CONSTRAINT follower_fk FOREIGN KEY (follower_id) REFERENCES users (id)
  MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;

ALTER TABLE followers
  ADD CONSTRAINT user_fk FOREIGN KEY (user_id) REFERENCES users (id)
  MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;

-- Don't allow users to follow themselves
ALTER TABLE followers
  ADD CONSTRAINT user_id CHECK (user_id != follower_id);


-- ############################################################################
-- # mentions
-- ############################################################################

ALTER TABLE mentions
  ADD CONSTRAINT user_fk FOREIGN KEY (user_id) REFERENCES users (id)
  MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;

ALTER TABLE mentions
  ADD CONSTRAINT tweet_fk FOREIGN KEY (tweet_id) REFERENCES tweets (id)
  MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


-- ############################################################################
-- # replies
-- ############################################################################

ALTER TABLE replies
  ADD CONSTRAINT tweet_fk FOREIGN KEY (tweet_id) REFERENCES tweets (id)
  MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;

ALTER TABLE replies
  ADD CONSTRAINT reply_fk FOREIGN KEY (reply_id) REFERENCES tweets (id)
  MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


-- ############################################################################
-- # reweets
-- ############################################################################

ALTER TABLE retweets
  ADD CONSTRAINT tweet_fk FOREIGN KEY (tweet_id) REFERENCES tweets (id)
  MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;

ALTER TABLE retweets
  ADD CONSTRAINT retweet_fk FOREIGN KEY (retweet_id) REFERENCES tweets (id)
  MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


-- ############################################################################
-- # tags
-- ############################################################################

ALTER TABLE tags
  ADD CONSTRAINT tweets_count CHECK (tweets >= 0);


-- ############################################################################
-- # taggings
-- ############################################################################

ALTER TABLE taggings
  ADD CONSTRAINT tag_fk FOREIGN KEY (tag_id) REFERENCES tags (id)
  MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;

ALTER TABLE taggings
  ADD CONSTRAINT tweet_fk FOREIGN KEY (tweet_id) REFERENCES tweets (id)
  MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;


-- ############################################################################
-- # tweets
-- ############################################################################

ALTER TABLE tweets
  ADD CONSTRAINT user_fk FOREIGN KEY (user_id) REFERENCES users (id)
  MATCH FULL ON UPDATE CASCADE ON DELETE CASCADE;

ALTER TABLE tweets ADD
  CONSTRAINT post_length CHECK (char_length(post) <= 140);


-- ############################################################################
-- # users
-- ############################################################################

ALTER TABLE users
  ADD CONSTRAINT mentions_count CHECK (mentions >= 0);

ALTER TABLE users
  ADD CONSTRAINT tweets_count CHECK (tweets >= 0);
-- ############################################################################
-- # tags
-- ############################################################################

CREATE UNIQUE INDEX ON tags (LOWER(name));


-- ############################################################################
-- # tweets
-- ############################################################################

CREATE INDEX ON tweets (user_id);


-- ############################################################################
-- # users
-- ############################################################################

CREATE UNIQUE INDEX ON users (LOWER(username));
-- ############################################################################
-- # favorites
-- ############################################################################

CREATE TRIGGER update_tweet_favorites
  AFTER INSERT OR UPDATE OR DELETE ON favorites
  FOR EACH ROW EXECUTE PROCEDURE counter_cache('tweets', 'favorites', 'tweet_id', 'id');

CREATE TRIGGER update_user_favorites
  AFTER INSERT OR UPDATE OR DELETE ON favorites
  FOR EACH ROW EXECUTE PROCEDURE counter_cache('users', 'favorites', 'user_id', 'id');


-- ############################################################################
-- # followers
-- ############################################################################

CREATE TRIGGER update_follower_following
  AFTER INSERT OR UPDATE OR DELETE ON followers
  FOR EACH ROW EXECUTE PROCEDURE counter_cache('users', 'following', 'follower_id', 'id');

CREATE TRIGGER update_user_followers
  AFTER INSERT OR UPDATE OR DELETE ON followers
  FOR EACH ROW EXECUTE PROCEDURE counter_cache('users', 'followers', 'user_id', 'id');


-- ############################################################################
-- # mentions
-- ############################################################################

CREATE TRIGGER update_user_mentions
  AFTER INSERT OR UPDATE OR DELETE ON mentions
  FOR EACH ROW EXECUTE PROCEDURE counter_cache('users', 'mentions', 'user_id', 'id');


-- ############################################################################
-- # replies
-- ############################################################################

CREATE TRIGGER update_tweet_replies
  AFTER INSERT OR UPDATE OR DELETE ON replies
  FOR EACH ROW EXECUTE PROCEDURE counter_cache('tweets', 'replies', 'tweet_id', 'id');


-- ############################################################################
-- # reweets
-- ############################################################################

CREATE TRIGGER update_tweet_retweets
  AFTER INSERT OR UPDATE OR DELETE ON retweets
  FOR EACH ROW EXECUTE PROCEDURE counter_cache('tweets', 'retweets', 'tweet_id', 'id');


-- ############################################################################
-- # tags
-- ############################################################################

CREATE TRIGGER delete_stale_tags
  AFTER UPDATE ON tags
  FOR EACH ROW WHEN (NEW.tweets = 0)
  EXECUTE PROCEDURE delete_stale_tag();


-- ############################################################################
-- # taggings
-- ############################################################################

CREATE TRIGGER update_tag_tweets
  AFTER INSERT OR UPDATE OR DELETE ON taggings
  FOR EACH ROW EXECUTE PROCEDURE counter_cache('tags', 'tweets', 'tag_id', 'id');


-- ############################################################################
-- # tweets
-- ############################################################################

CREATE TRIGGER update_user_tweets
  AFTER INSERT OR UPDATE OR DELETE ON tweets
  FOR EACH ROW EXECUTE PROCEDURE counter_cache('users', 'tweets', 'user_id', 'id');

-------------------------------------------------------------------------------

CREATE TRIGGER parse_mentions
  BEFORE INSERT OR UPDATE ON tweets
  FOR EACH ROW EXECUTE PROCEDURE parse_mentions_from_post();

CREATE TRIGGER create_mentions
  AFTER INSERT OR UPDATE ON tweets
  FOR EACH ROW EXECUTE PROCEDURE create_new_mentions();

CREATE TRIGGER delete_mentions
  AFTER UPDATE ON tweets
  FOR EACH ROW WHEN (NEW.mentions IS DISTINCT FROM OLD.mentions)
  EXECUTE PROCEDURE delete_old_mentions();

-------------------------------------------------------------------------------

CREATE TRIGGER parse_taggings
  BEFORE INSERT OR UPDATE ON tweets
  FOR EACH ROW EXECUTE PROCEDURE parse_tags_from_post();

CREATE TRIGGER create_taggings
  AFTER INSERT OR UPDATE ON tweets
  FOR EACH ROW EXECUTE PROCEDURE create_new_taggings();

CREATE TRIGGER delete_taggings
  AFTER UPDATE ON tweets
  FOR EACH ROW WHEN (NEW.tags IS DISTINCT FROM OLD.tags)
  EXECUTE PROCEDURE delete_old_taggings();
-- ############################################################################
-- # Seed data
-- ############################################################################

INSERT INTO users (username) VALUES
  ('bob'),
  ('doug'),
  ('jane'),
  ('steve'),
  ('tom');

INSERT INTO tweets (post, user_id) VALUES
  ('My first tweet!', random.id('users')),
  ('Another tweet with a tag! #hello-world @missing', random.id('users')),
  ('My second tweet! #hello-world #hello-world-again', random.id('users')),
  ('Is anyone else hungry? #imHUNGRY #gimmefood @TOM @jane', random.id('users')),
  ('@steve hola!', random.id('users')),
  ('@bob I am! #imhungry #metoo #gimmefood #now', random.id('users'));

INSERT INTO favorites (user_id, tweet_id)
SELECT id as user_id, random.id('tweets') as tweet_id
FROM users;

INSERT INTO followers (follower_id, user_id)
SELECT id as follower_id, random.id('users', id) as user_id
FROM users;

INSERT INTO replies (tweet_id, reply_id)
SELECT id as tweet_id, random.id('tweets', id) as reply_id
FROM tweets
LIMIT 2;

INSERT INTO retweets (tweet_id, retweet_id)
SELECT id as tweet_id, random.id('tweets', id) as retweet_id
FROM tweets
LIMIT 2;


-- ############################################################################
-- # Debug output
-- ############################################################################

SELECT id, username, followers, following, favorites, mentions, tweets FROM users;
SELECT * FROM mentions;

-------------------------------------------------------------------------------

DELETE FROM tweets
WHERE id IN (
  SELECT t.id
  FROM tweets t
  ORDER BY random()
  LIMIT 1
);

UPDATE tweets
SET post = 'replaced!'
WHERE id IN (
  SELECT t.id
  FROM tweets t
  ORDER BY random()
  LIMIT 1
);

SELECT username, tweets.favorites, replies, retweets, tweets.mentions, tags
FROM tweets JOIN users on tweets.user_id = users.id;

-------------------------------------------------------------------------------

SELECT * FROM taggings;
SELECT id, name, tweets FROM tags;

SELECT * from views.retweets;
