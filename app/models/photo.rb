=begin
The purpose of this model class is to encapsulate all information and content access to a 
photograph. This model uses [`GridFS`](https://docs.mongodb.org/manual/core/gridfs/) -- 
rather than a usual MongoDB collection like `places` since there will be an 
information aspect and a raw data aspect to this model type. This model class 
will also be responsible for extracting geolocation coordinates from each `photo` 
and locating the nearest `place` (within distance tolerances) to where that `photo` was taken.
To simplify the inspection of the photo image data, all photos handled by this model 
class will be assumed to be `jpeg` images.  You may use the [`exifr gem`]
(https://rubygems.org/gems/exifr/) to extract available geographic coordinates from 
each `photo`.
=end

class Photo
  include Mongoid::Document
  # attributes:
  #   * a read/write attribute called `id` that will be of type `String` to hold the 
  #   String form of the GridFS file `_id` attribute
  #   * a read/write attribute called `location` that will be of type `Point` to hold 
  #   the location information of where the photo was taken.
  #   * a write-only (for now) attribute called `contents` that will be used to import and access
  #   the raw data of the photo. This will have varying data types depending on 
  #   context.
  attr_accessor :id, :location
  attr_writer :contents

  # Class method `mongo_client` that returns a MongoDB Client from Mongoid
  #   referencing the default database from the `config/mongoid.yml` file 
  #   (**Hint**: `Mongoid::Clients.default`)
  def self.mongo_client
  	db = Mongo::Client.new('mongodb://localhost:27017')
  end

  # `initialize` method used to initialize the instance attributes of `Photo` 
  # from the hash returned from queries like `mongo_client.database.fs.find`. 
  # This method must
  #   * initialize `@id` to the string form of `_id` and `@location` to the `Point` form of
  #     `metadata.location` if these exist. The document hash is likely coming from query 
  #     results coming from `mongo_client.database.fs.find`.
  #   * create a default instance if no hash is present
  #   
  def initialize(hash={})
  	@id = hash[:_id].to_s if !hash[:_id].nil?
  	if !hash[:metadata].nil?
  		@location = Point.new(hash[:metadata][:location]) if !hash[:metadata][:location].nil?
  		@place = hash[:metadata][:place]
  	end
  end

  #Checks if instance from GridFS exists
  def persisted?
  	!@id.nil?
  end

  #Saves or updates photos
  def save
    if !persisted?
      gps = EXIFR::JPEG.new(@contents).gps
      description = {}
      description[:content_type] = 'image/jpeg'
      description[:metadata] = {}
      @location = Point.new(:lng => gps.longitude, :lat => gps.latitude)
      description[:metadata][:location] = @location.to_hash
      description[:metadata][:place] = @place

      if @contents
        @contents.rewind
        grid_file = Mongo::Grid::File.new(@contents.read, description)
        id = self.class.mongo_client.database.fs.insert_one(grid_file)
        @id = id.to_s
      end
    else
      self.class.mongo_client.database.fs.find(:_id => BSON::ObjectId(@id))
        .update_one(:$set => {
          :metadata => {
            :location => @location.to_hash,
            :place => @place
          }
        })
    end
  end

  #Returns photos
  def self.all(skip = 0, limit = nil)
  	docs = mongo_client.database.fs.find({}).skip(skip)
  	docs = docs.limit(limit) if !limit.nil?

  	docs.map do |doc|
  		Photo.new(doc)
  	end
  end

  #Finds a single photo based on id
  def self.find(id)
  	doc = mongo_client.database.fs.find(:_id => BSON::ObjectId(id)).first
  	if doc.nil?
  		return nil
  	else
  		return Photo.new(doc)
  	end
  end

  #Returns data contents of file
  def contents
  	doc = self.class.mongo_client.database.fs.find_one(:_id => BSON::ObjectId(@id))
  	if doc
  	  buffer = ""
  	  doc.chunks.reduce([]) do |x, chunk|
  	    buffer << chunk.data.data
  	  end
  	  return buffer
  	end
  end

  #Delete object from Grid
  def destroy
  	self.class.mongo_client.database.fs.find(:_id => BSON::ObjectId(@id)).delete_one
  end

  #Helper method to find nearest photo place
  def find_nearest_place_id(max_dist)
  	place = Place.near(@location, max_dist).limit(1).projection(:_id => 1).first

  	if place.nil?
  		return nil
  	else
  		return place[:_id]
  	end
  end

  #Place getter
  def place
    if !@place.nil?
    	Place.find(@place.to_s)
    end
  end

  #Place setter
  def place=(place)
    if place.class == Place
    	@place = BSON::ObjectId.from_string(place.id)
    elsif place.class == String
    	@place = BSON::ObjectId.from_string(place)
    else
    	@place = place
    end
  end

  #Finds photo for place id
  def self.find_photos_for_place(place_id)
  	place_id = BSON::ObjectId.from_string(place_id.to_s)
  	mongo_client.database.fs.find(:'metadata.place' => place_id)
  end

end
