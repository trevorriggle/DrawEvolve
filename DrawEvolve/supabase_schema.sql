-- DrawEvolve Supabase Schema
-- Run this in your Supabase SQL Editor

-- Create drawings table
CREATE TABLE IF NOT EXISTS drawings (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
    title TEXT NOT NULL,
    image_data BYTEA NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT NOW() NOT NULL
);

-- Create index on user_id for faster queries
CREATE INDEX IF NOT EXISTS drawings_user_id_idx ON drawings(user_id);

-- Create index on created_at for sorting
CREATE INDEX IF NOT EXISTS drawings_created_at_idx ON drawings(created_at DESC);

-- Enable Row Level Security
ALTER TABLE drawings ENABLE ROW LEVEL SECURITY;

-- Policy: Users can only view their own drawings
CREATE POLICY "Users can view their own drawings"
    ON drawings FOR SELECT
    USING (auth.uid() = user_id);

-- Policy: Users can insert their own drawings
CREATE POLICY "Users can insert their own drawings"
    ON drawings FOR INSERT
    WITH CHECK (auth.uid() = user_id);

-- Policy: Users can update their own drawings
CREATE POLICY "Users can update their own drawings"
    ON drawings FOR UPDATE
    USING (auth.uid() = user_id)
    WITH CHECK (auth.uid() = user_id);

-- Policy: Users can delete their own drawings
CREATE POLICY "Users can delete their own drawings"
    ON drawings FOR DELETE
    USING (auth.uid() = user_id);

-- Function to automatically update updated_at timestamp
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ language 'plpgsql';

-- Trigger to call the function on update
CREATE TRIGGER update_drawings_updated_at
    BEFORE UPDATE ON drawings
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();
