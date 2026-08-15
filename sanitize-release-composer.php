#!/usr/bin/env php
<?php
/**
 * Prepare composer.json/composer.lock for production (powerps-core release).
 * Removes dev-only encrypter + path repos and refreshes lock content-hash.
 */
declare(strict_types=1);

$root = $argv[1] ?? null;
if ($root === null || ! is_dir($root)) {
    fwrite(STDERR, "Usage: sanitize-release-composer.php <project-dir>\n");
    exit(1);
}

$jsonPath = rtrim($root, '/').'/composer.json';
$lockPath = rtrim($root, '/').'/composer.lock';

if (! is_file($jsonPath)) {
    fwrite(STDERR, "composer.json not found in {$root}\n");
    exit(1);
}

$data = json_decode((string) file_get_contents($jsonPath), true);
if (! is_array($data)) {
    fwrite(STDERR, "Invalid composer.json\n");
    exit(1);
}

unset($data['require-dev']['sbamtr/laravel-source-encrypter']);
if (isset($data['autoload-dev']['psr-4']['sbamtr\\LaravelSourceEncrypter\\'])) {
    unset($data['autoload-dev']['psr-4']['sbamtr\\LaravelSourceEncrypter\\']);
}
if (! empty($data['repositories'])) {
    $data['repositories'] = array_values(array_filter(
        $data['repositories'],
        static fn (array $repo): bool => ($repo['type'] ?? '') !== 'path'
    ));
}

$json = json_encode($data, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES)."\n";
file_put_contents($jsonPath, $json);

if (! is_file($lockPath)) {
    exit(0);
}

$lock = json_decode((string) file_get_contents($lockPath), true);
if (! is_array($lock)) {
    fwrite(STDERR, "Invalid composer.lock\n");
    exit(1);
}

if (! empty($lock['packages-dev'])) {
    $lock['packages-dev'] = array_values(array_filter(
        $lock['packages-dev'],
        static fn (array $package): bool => ($package['name'] ?? '') !== 'sbamtr/laravel-source-encrypter'
    ));
}

$lock['content-hash'] = composer_content_hash($data);
file_put_contents($lockPath, json_encode($lock, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES)."\n");

function composer_content_hash(array $composer): string
{
    $relevantKeys = [
        'name',
        'version',
        'require',
        'require-dev',
        'conflict',
        'replace',
        'provide',
        'minimum-stability',
        'prefer-stable',
        'repositories',
        'extra',
    ];

    $relevantContent = [];
    foreach (array_intersect($relevantKeys, array_keys($composer)) as $key) {
        $relevantContent[$key] = $composer[$key];
    }
    if (isset($composer['config']['platform'])) {
        $relevantContent['config']['platform'] = $composer['config']['platform'];
    }

    ksort($relevantContent);

    return md5((string) json_encode($relevantContent));
}
