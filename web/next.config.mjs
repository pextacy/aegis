/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
  typescript: {
    // A type error is a build failure. Shipping a dashboard that mis-reads a
    // treasury balance because a type was silently widened is worse than not
    // shipping it.
    ignoreBuildErrors: false,
  },
};

export default nextConfig;
