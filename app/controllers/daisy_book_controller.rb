require 'fileutils'
require 'RMagick'
require 'nokogiri'
require 'tempfile'
require 'xml/xslt'

class NonDaisyXMLException < Exception
end

class MissingBookUIDException < Exception
end

class UnrecognizedProdnoteException < Exception
end

class ShowAlertAndGoBack < Exception
  def initialize(message)
    @message = message
  end
  
  attr_reader :message
end

class DaisyBookController < ApplicationController
  def get_daisy_with_descriptions
    begin
      book_directory = session[:daisy_directory]
      zip_directory = session[:zip_directory]
      contents_filename = get_daisy_contents_xml_name(book_directory)
      relative_contents_path = contents_filename[zip_directory.length..-1]
      if(relative_contents_path[0,1] == '/')
        relative_contents_path = relative_contents_path[1..-1]
    end
      xml = get_xml_contents_with_updated_descriptions(contents_filename)
      zip_filename = create_zip(session[:daisy_file], relative_contents_path, xml)    
      basename = File.basename(contents_filename)
      send_file zip_filename, :type => 'application/zip; charset=utf-8', :filename => basename + '.zip', :disposition => 'attachment' 
    rescue ShowAlertAndGoBack => e
      redirect_to :back, :alert => e.message
      return
    end
  end
  
  def get_xml_with_descriptions
    begin
      book_directory = session[:daisy_directory]
      zip_directory = session[:zip_directory]
      contents_filename = get_daisy_contents_xml_name(book_directory)
      xml = get_xml_contents_with_updated_descriptions(contents_filename)
      send_data xml, :type => 'application/xml; charset=utf-8', :filename => contents_filename, :disposition => 'attachment' 
    rescue ShowAlertAndGoBack => e
      redirect_to :back, :alert => e.message
      return
    end
  end

  def get_xml_contents_with_updated_descriptions(contents_filename)
    xml_file = File.read(contents_filename)
    begin
      xml = get_contents_with_updated_descriptions(xml_file)
    rescue UnrecognizedProdnoteException
      logger.info "#{caller_info} Unrecognized prodnote elements in #{contents_filename}"
      raise ShowAlertAndGoBack.new("Unable to update descriptions because the uploaded book contained descriptions from other sources")
    rescue NonDaisyXMLException => e
      logger.info "#{caller_info} Uploaded non-dtbook #{contents_filename}"
      raise ShowAlertAndGoBack.new("Uploaded file must be a valid Daisy book XML content file")
    rescue MissingBookUIDException => e
      logger.info "#{caller_info} Uploaded dtbook without UID #{contents_filename}"
      raise ShowAlertAndGoBack.new("Uploaded Daisy book XML content file must have a UID element")
    rescue Nokogiri::XML::XPath::SyntaxError => e
      logger.info "#{caller_info} Uploaded invalid XML file #{contents_filename}"
      logger.info "#{e.class}: #{e.message}"
      logger.info "Line #{e.line}, Column #{e.column}, Code #{e.code}"
      raise ShowAlertAndGoBack.new("Uploaded file must be a valid Daisy book XML content file")
    rescue Exception => e
      logger.info "#{caller_info} Unexpected exception processing #{contents_filename}:"
      logger.info "#{e.class}: #{e.message}"
      logger.info e.backtrace.join("\n")
      raise ShowAlertAndGoBack.new("An unexpected error has prevented processing that file")
    end
    
    return xml
  end

  def submit
    book = params[:book]
    if !book
      flash[:alert] = "Must specify a book file to process"
      redirect_to :action => 'upload'
      return
    end
    
    if !valid_daisy_zip?(book.path)
      flash[:alert] = "Uploaded file must be a valid Daisy (zip) file"
      redirect_to :action => 'upload'
      return
    end
    
    zip_directory = unzip_to_temp(book.path)
    session[:zip_directory] = zip_directory
    top_level_entries = Dir.entries(zip_directory)
    top_level_entries.delete('.')
    top_level_entries.delete('..')
    if(top_level_entries.size == 1)
      book_directory = File.join(zip_directory, top_level_entries.first)
    else
      book_directory = zip_directory
    end
    session[:daisy_directory] = book_directory

    copy_of_daisy_file = File.join(zip_directory, "Daisy.zip")
    FileUtils.cp(book.path, copy_of_daisy_file)
    session[:daisy_file] = copy_of_daisy_file

    redirect_to :action => 'edit'
  end

  def edit
    render :layout => 'frames'
  end
  
  def file
    directory_name = params[:directory]
    if !directory_name
      directory_name = ''
    end
    file_name = params[:file]
    book_directory = session[:daisy_directory]
    directory = File.join(book_directory, directory_name)
    file = File.join(directory, file_name)
    timestamp = File.stat(file).ctime
    if(stale?(:last_modified => timestamp))
      content_type = 'text/plain'
      case File.extname(file).downcase
      when '.jpg', '.jpeg'
        content_type = 'image/jpeg'
      when '.png'
        content_type = 'image/png'
      end
      contents = File.read(file)
      response.headers['Last-Modified'] = timestamp.httpdate
      render :text => contents, :content_type => content_type
    end
  end
  
  def content
    book_directory = session[:daisy_directory]
    contents_filename = get_daisy_contents_xml_name(book_directory)
    xml = File.read(contents_filename)
    xsl_filename = 'app/views/xslt/daisyTransform.xsl'
    xsl = File.read(xsl_filename)
    contents = xslt(xml, xsl)
    render :text => contents, :content_type => 'text/html'
  end
  
  def side_bar
    configure_images
  end

  def top_bar
    configure_images
  end  
    
  def valid_daisy_zip?(file)
    puts "valid_daisy_zip?(#{file})"
    begin
      Zip::Archive.open(file) do |zipfile|
        zipfile.each do |entry|
          if entry.name =~ /\.ncx$/
            return true
          end
        end
      end
    rescue Exception => e
      puts e
      puts e.backtrace.join("\n")
      return false
    end
    
    return false
  end
  
private
  def unzip_to_temp(zipped_file)
    dir = Dir.mktmpdir
    Zip::Archive.open(zipped_file) do |zipfile|
      zipfile.each do |entry|
        destination = File.join(dir, entry.name)
        if entry.directory?
          FileUtils.mkdir_p(destination)
        else
          dirname = File.join(dir, File.dirname(entry.name))
          FileUtils.mkdir_p(dirname) unless File.exist?(dirname)
          open(destination, 'wb') do |f|
            f << entry.read
          end
        end
      end
    end    
    return dir
  end
  
  def get_daisy_contents_xml_name(book_directory)
    return Dir.glob(File.join(book_directory, '*.xml'))[0]
  end
  
  def xslt(xml, xsl)
    engine = XML::XSLT.new
    engine.xml = xml
    engine.xsl = xsl
    engine.parameters = {"form_authenticity_token" => form_authenticity_token}
    return engine.serve
  end
  
  def get_contents_with_updated_descriptions(file)
    doc = Nokogiri::XML file
    
    root = doc.xpath(doc, "/xmlns:dtbook")
    if root.size != 1
      raise NonDaisyXMLException.new
    end
  
    xpath_uid = "//xmlns:meta[@name='dtb:uid']"
    matches = doc.xpath(doc, xpath_uid)
    if matches.size != 1
      raise MissingBookUIDException.new
    end
    node = matches.first
    book_uid = node.attributes['content'].content
  
    matching_images = DynamicImage.where("uid = ?", book_uid)
    matching_images.each do | dynamic_image |
      image_location = dynamic_image.image_location
      image = doc.at_xpath( doc, "//xmlns:img[@src='#{image_location}']")
      parent = doc.at_xpath( doc, "//xmlns:img[@src='#{image_location}']/..")
  
      dynamic_description = dynamic_image.best_description
      if(!dynamic_description)
        logger.info "Image #{book_uid} #{image_location} is in database but with no descriptions"
        next
      end
      
      if !parent
        logger.info "Missing img element for database description #{book_uid} #{image_location}"
        next
      end
      
      is_parent_image_group = parent.matches?('//xmlns:imggroup')
      if(!is_parent_image_group)
        image_group = Nokogiri::XML::Node.new "imggroup", doc
        image_group.parent = parent
        
        parent.children.delete(image)
        image.parent = image_group
        parent = image_group
      end
  
      image_id = image['id']
  
      prodnote = parent.at_xpath("./xmlns:prodnote")
      if(!prodnote)
        prodnote = Nokogiri::XML::Node.new "prodnote", doc 
        image.add_next_sibling prodnote
      elsif(prodnote['id'] != create_prodnote_id(image_id))
        raise UnrecognizedProdnoteException.new
      end
      
      prodnote.content = dynamic_description.body
      prodnote['render'] = 'optional'
      prodnote['imgref'] = image_id
      prodnote['id'] = create_prodnote_id(image_id)
      prodnote['showin'] = 'blp'
    end
    
    return doc.to_xml
  end
  
  def create_prodnote_id(image_id)
    "pnid_#{image_id}"
  end
  
  def caller_info
    return "#{request.remote_addr}"
  end
  
  def create_zip(old_daisy_zip, contents_filename, new_xml_contents)
    new_daisy_zip = Tempfile.new('baked-daisy')
    new_daisy_zip.close
    FileUtils.cp(old_daisy_zip, new_daisy_zip.path)
    Zip::Archive.open(new_daisy_zip.path) do |zipfile|
      zipfile.num_files.times do |index|
        if(zipfile.get_name(index) == contents_filename)
          zipfile.replace_buffer(index, new_xml_contents)
          break
        end
      end
    end
    return new_daisy_zip.path
  end

  def configure_images
    book_directory = session[:daisy_directory]
    contents_filename = get_daisy_contents_xml_name(book_directory)
    xml = File.read(contents_filename)
    doc = Nokogiri::XML xml
    @images = []
    images = doc.xpath( doc, "//xmlns:img")
    images.each do | image_node |
      img_id = image_node['id']
      if(!img_id)
        puts "Skipping image with no id: #{image_node.path}"
        next
      end
      img_src = image_node['src']
      if(!img_src)
        puts "Skipping image with no src: id=#{img_id}"
        next
      end
      image_data = {'id' => img_id, 'src' => "book/#{img_src}"}
      image_file = File.join(book_directory, img_src)
      if File.exists?(image_file)
        image = Magick::ImageList.new(image_file)[0]
        image_data['width'] = image.base_columns
        image_data['height'] = image.base_rows
        image.destroy!
      else
        image_data['width'] = 20
        image_data['height'] = 20
      end
      @images << image_data
    end
  end

end
