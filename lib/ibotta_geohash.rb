require 'ibotta_geohash/version'

# TODO document encode/decode
# TODO perf test
# TODO compare to C impl

#Pure ruby geohash library
#
# Based on: pr_geohash
# https://github.com/masuidrive/pr_geohash
# Yuichiro MASUI
# Geohash library for pure ruby
# Distributed under the MIT License
#
# Based library is
#// http://github.com/davetroy/geohash-js/blob/master/geohash.js
#// geohash.js
#// Geohash library for Javascript
#// (c) 2008 David Troy
#// Distributed under the MIT License
#
module IbottaGeohash

  BITS = [0x10, 0x08, 0x04, 0x02, 0x01].freeze
  BASE32 = "0123456789bcdefghjkmnpqrstuvwxyz".freeze

  MERCATOR = (-20037726.37..20037726.37).freeze
  WGS84_LAT = (-85.05113..85.05113).freeze
  WGS84_LON = (-180.0..180.0).freeze

  # EARTH_RADIUS_IN_METERS = 6372797.560856
  # DEG_TO_RAD = Math::PI / 180.0
  # RAD_TO_DEG = 180.0 / Math::PI

  NEIGHBORS = {
    :right  => { :even => "bc01fg45238967deuvhjyznpkmstqrwx", :odd => "p0r21436x8zb9dcf5h7kjnmqesgutwvy" },
    :left   => { :even => "238967debc01fg45kmstqrwxuvhjyznp", :odd => "14365h7k9dcfesgujnmqp0r2twvyx8zb" },
    :top    => { :even => "p0r21436x8zb9dcf5h7kjnmqesgutwvy", :odd => "bc01fg45238967deuvhjyznpkmstqrwx" },
    :bottom => { :even => "14365h7k9dcfesgujnmqp0r2twvyx8zb", :odd => "238967debc01fg45kmstqrwxuvhjyznp" }
  }.freeze

  BORDERS = {
    :right  => { :even => "bcfguvyz", :odd => "prxz" },
    :left   => { :even => "0145hjnp", :odd => "028b" },
    :top    => { :even => "prxz"    , :odd => "bcfguvyz" },
    :bottom => { :even => "028b"    , :odd => "0145hjnp" }
  }.freeze

  class << self

    #decode bounding box from geohash string
    # @todo  reorder bounds?
    # @todo  see if faster way (less array access?)
    # @todo  see if split() faster than scan()
    # @param [String] geohash string
    # @return [Array<Array>] decoded bounding box [[south latitude, west longitude],[north latitude, east longitude]]
    def decode(geohash)
      latlng = [[-90.0, 90.0], [-180.0, 180.0]]
      is_lng = 1
      geohash.downcase.scan(/./) do |c|
        BITS.each do |mask|
          latlng[is_lng][(BASE32.index(c) & mask)==0 ? 1 : 0] = (latlng[is_lng][0] + latlng[is_lng][1]) / 2
          is_lng ^= 1
        end
      end
      latlng.transpose
    end

    #decode center of geohash area
    # @todo  see if faster way? other libs do this first, calc bounding from it
    # @param [String] geohash string
    # @return [Array<Float>] latitude, longitude of center
    def decode_center(geohash)
      res = decode(geohash)
      [((res[0][0] + res[1][0]) / 2), ((res[0][1] + res[1][1]) / 2)]
    end

    #Encode latitude and longitude into geohash string
    # @todo  see if faster way? less array access?
    # @param [Float] latitude
    # @param [Float] longitude
    # @param [Integer] precision number of characters
    # @return [String] encoded
    def encode(latitude, longitude, precision=12)
      latlng = [latitude, longitude]
      points = [[-90.0, 90.0], [-180.0, 180.0]]
      is_lng = 1
      (0...precision).map do
        ch = 0
        5.times do |bit|
          mid = (points[is_lng][0] + points[is_lng][1]) / 2
          points[is_lng][latlng[is_lng] > mid ? 0 : 1] = mid
          ch |=  BITS[bit] if latlng[is_lng] > mid
          is_lng ^= 1
        end
        BASE32[ch,1]
      end.join
    end

    # Calculate each 8 direction neighbors as geohash
    # @param [String] geohash
    # @return [Array<String>] neighbors in clockwise (top, topright, right, ...). Invalid regions at the poles are excluded
    def neighbors(geohash)
      [[:top, :right], [:right, :bottom], [:bottom, :left], [:left, :top]].map do |dirs|
        point = adjacent(geohash, dirs[0])
        [point, adjacent(point, dirs[1])]
      end.flatten.compact
    end

    #calculate one adjacent neighbor
    # @param [String] geohash
    # @param [Symbol] dir which direction (top, right, bottom left)
    # @return [String] neighbor in that direction (or nil if invalid)
    def adjacent(geohash, dir)
      return if geohash.nil? || geohash.empty?
      base, lastChr = geohash[0..-2], geohash[-1,1]
      type = (geohash.length % 2)==1 ? :odd : :even
      if BORDERS[dir][type].include?(lastChr)
        base = adjacent(base, dir)
        if base.nil?
          return if dir == :top || dir == :bottom
          base = ''
        end
      end
      base + BASE32[NEIGHBORS[dir][type].index(lastChr),1]
    end

    #get geohashes covering a radius
    # @param [Float] lat
    # @param [Flaot] lon
    # @param [Float] radius_meters
    # @return [Array<String>] hashes (neighbors and center) covering radius in clockwise (top, topright, right, ...). neighbors not covering radius are excluded
    def areas_by_radius(lat, lon, radius_meters)
      #get min/max latitude and longitude of radius around point
      min_lat, min_lon, max_lat, max_lon = radius_box = bounding_box(lat, lon, radius_meters)

      #estimate the size of boxes to target
      steps = estimate_steps_by_radius(radius_meters)
      #re-encode point at steps
      hash = encode(lat, lon, steps)

      #get neighbors of box
      n_n, n_ne, n_e, n_se, n_s, n_sw, n_w, n_nw = nb = neighbors(hash)

      #get original bounding box
      s, w, n, e = area_box = decode(hash).flatten

      if s < min_lat
        #area already covers south bounds of target
        nb.delete(n_se)
        nb.delete(n_s)
        nb.delete(n_sw)
      end
      if n > max_lat
        #already covers north bounds of target
        nb.delete(n_ne)
        nb.delete(n_n)
        nb.delete(n_nw)
      end
      if w < min_lon
        #already covers west bounds of target
        nb.delete(n_nw)
        nb.delete(n_w)
        nb.delete(n_sw)
      end
      if e > max_lon
        #already covers east bounds of target
        nb.delete(n_ne)
        nb.delete(n_e)
        nb.delete(n_se)
      end

      #add center hash
      nb.unshift(hash)

      #return remaining neighbor list
      nb
    end

    #estimate steps needed to cover radius
    # @param [Float] radius_meters
    # @return [Integer] steps required
    def estimate_steps_by_radius(radius_meters)
      step = 1
      v = radius_meters
      while v < MERCATOR.max
        v *= 2
        step += 1
      end
      step -= 1
      step
    end

    #get bounding box around a radius (adjusted for latitude)
    # @todo  reorder return to match decode?
    # @param [Float] lat
    # @param [Float] lon
    # @param [Flaot] radius_meters
    # @return [Array] min_lat, min_long, max_lat, max_long
    def bounding_box(lat, lon, radius_meters)
      radius_meters  = radius_meters.to_f
      delta_lat = radius_meters / (111320.0 * Math.cos(lat))
      delta_lon = radius_meters / 110540.0
      [
        lat - delta_lat,
        lon - delta_lon,
        lat + delta_lat,
        lon + delta_lon
      ]
    end
  end

end # module Geohash

#setup class aliases
GeoHash = IbottaGeohash
