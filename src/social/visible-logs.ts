import { sql } from "kysely";

/**
 * Whether the viewer may see a log anywhere outside the feed: on its author's profile, or to give
 * kudos and comment. Wider than the feed, which only shows people the viewer follows: a public log
 * is also visible to anyone when its author's account isn't private.
 *
 * Expects the query to join `users as author` on the log's author, `follows as viewer_follow` for
 * the viewer following the author, and `follows as author_follow` for the author following the
 * viewer, as `getFeedFromDatabase` and `findVisibleLog` do.
 */
export function visibleOutsideFeed(viewerId: string) {
  return sql<boolean>`(
    logs.user_id = ${viewerId}
    OR (logs.visibility = 'public' AND (viewer_follow.follower_id IS NOT NULL OR NOT author.is_private))
    OR (logs.visibility = 'friends_only' AND author_follow.following_id IS NOT NULL)
  )`;
}
