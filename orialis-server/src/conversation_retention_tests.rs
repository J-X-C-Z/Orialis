use super::*;

#[tokio::test]
async fn expires_only_conversations_without_activity_for_seven_days() {
    let pool = SqlitePoolOptions::new()
        .max_connections(1)
        .connect("sqlite::memory:")
        .await
        .unwrap();
    sqlx::migrate!("./migrations").run(&pool).await.unwrap();
    sqlx::query("INSERT INTO users (id,username,password_hash) VALUES ('u1','u1','hash')")
        .execute(&pool)
        .await
        .unwrap();

    for (id, is_default, updated_at) in [
        ("old-empty", 0, "2026-01-01T00:00:00Z"),
        ("old-with-old-message", 0, "2026-01-01T00:00:00Z"),
        ("old-with-recent-message", 0, "2026-01-01T00:00:00Z"),
        ("default", 1, "2026-01-01T00:00:00Z"),
    ] {
        sqlx::query(
            "INSERT INTO conversations (id,user_id,title,is_default,created_at,updated_at)
             VALUES (?, 'u1', ?, ?, ?, ?)",
        )
        .bind(id)
        .bind(id)
        .bind(is_default)
        .bind(updated_at)
        .bind(updated_at)
        .execute(&pool)
        .await
        .unwrap();
    }
    for (id, conversation_id, created_at) in [
        (
            "old-message",
            "old-with-old-message",
            "2026-01-01T00:00:00Z",
        ),
        (
            "recent-message",
            "old-with-recent-message",
            "2026-10-24T00:00:00Z",
        ),
    ] {
        sqlx::query(
            "INSERT INTO messages (id,user_id,conversation_id,role,content,created_at,updated_at)
             VALUES (?, 'u1', ?, 'user', 'hello', ?, ?)",
        )
        .bind(id)
        .bind(conversation_id)
        .bind(created_at)
        .bind(created_at)
        .execute(&pool)
        .await
        .unwrap();
    }

    expire_inactive_conversations(&pool, Some("u1"))
        .await
        .unwrap();
    let rows = sqlx::query_as::<_, (String, Option<String>)>(
        "SELECT id,deleted_at FROM conversations WHERE user_id='u1' ORDER BY id",
    )
    .fetch_all(&pool)
    .await
    .unwrap();
    let deleted = rows
        .into_iter()
        .filter_map(|(id, deleted_at)| deleted_at.map(|_| id))
        .collect::<Vec<_>>();
    assert_eq!(deleted, vec!["old-empty", "old-with-old-message"]);
}
