-- Optional metadata keeps older analysis rows and workers compatible.
ALTER TABLE memory_analyses ADD COLUMN category TEXT CHECK (category IN ('ai', 'other'));
ALTER TABLE memory_analyses ADD COLUMN source_url TEXT;
ALTER TABLE memory_analyses ADD COLUMN video_status TEXT CHECK (video_status IN ('none', 'analyzed', 'unavailable'));
ALTER TABLE memory_analyses ADD COLUMN video_summary TEXT;
ALTER TABLE memory_analyses ADD COLUMN video_error TEXT;
