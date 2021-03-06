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
