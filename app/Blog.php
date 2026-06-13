<?php

namespace App;

use Database\Factories\BlogFactory;
use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\SoftDeletes;
use Illuminate\Support\Facades\Storage;

class Blog extends Model
{
    use HasFactory, SoftDeletes;

    protected static function newFactory()
    {
        return BlogFactory::new();
    }

    protected $fillable = [
        'title', 'description', 'content', 'image', 'published_at', 'category_id',
    ];

    /**
     * Resolve a usable image URL, falling back to a placeholder when the file
     * is missing (e.g. seed data) so the UI never shows a broken image.
     */
    public function getImageUrlAttribute(): string
    {
        $fallback = asset('images/place-1.jpg');

        if (! $this->image) {
            return $fallback;
        }

        // Image referenced directly from the public/ directory.
        if (str_starts_with($this->image, 'images/')) {
            return asset($this->image);
        }

        // Stored on the public disk (storage/app/public → /storage).
        if (Storage::disk('public')->exists($this->image)) {
            return asset('storage/'.$this->image);
        }

        return $fallback;
    }

    /**
     * delete image from storage
     *
     * @return void
     */
    public function deleteImage()
    {
        Storage::disk('public')->delete($this->image);
    }

    public function category()
    {
        return $this->belongsTo(Category::class);
    }

    /**
     * Scope for published blog posts.
     */
    public function scopePublished($query)
    {
        return $query->whereNotNull('published_at')
            ->where('published_at', '<=', now());
    }

    /**
     * Scope for recent blog posts.
     */
    public function scopeRecent($query, $limit = 10)
    {
        return $query->orderBy('published_at', 'desc')->limit($limit);
    }

    /**
     * Scope for posts by category.
     */
    public function scopeInCategory($query, $categoryId)
    {
        return $query->where('category_id', $categoryId);
    }
}
