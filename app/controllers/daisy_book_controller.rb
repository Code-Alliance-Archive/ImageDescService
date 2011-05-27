require 'fileutils'
require 'nokogiri'
require 'tempfile'
require 'xml/xslt'
require 'zip/zipfilesystem'

class NonDaisyXMLException < Exception
end

class MissingBookUIDException < Exception
end

class UnrecognizedProdnoteException < Exception
end

class DaisyBookController < ApplicationController
  def get_daisy_with_descriptions
    book_directory = session[:daisy_directory]
    contents_filename = get_daisy_contents_xml_name(book_directory)
    xml_file = File.read(contents_filename)
    begin
      xml = get_contents_with_updated_descriptions(xml_file)
    rescue UnrecognizedProdnoteException
      logger.info "#{caller_info} Unrecognized prodnote elements in #{contents_filename}"
      redirect_to :back, :alert => "Unable to update descriptions because the uploaded book contained descriptions from other sources"
      return
    rescue NonDaisyXMLException => e
      logger.info "#{caller_info} Uploaded non-dtbook #{contents_filename}"
      redirect_to :back, :alert => "Uploaded file must be a valid Daisy book XML content file"
      return
    rescue MissingBookUIDException => e
      logger.info "#{caller_info} Uploaded dtbook without UID #{contents_filename}"
      redirect_to :back, :alert => "Uploaded Daisy book XML content file must have a UID element"
      return
    rescue Nokogiri::XML::XPath::SyntaxError => e
      logger.info "#{caller_info} Uploaded invalid XML file #{contents_filename}"
      logger.info "#{e.class}: #{e.message}"
      logger.info "Line #{e.line}, Column #{e.column}, Code #{e.code}"
      redirect_to :back, :alert => "Uploaded file must be a valid Daisy book XML content file"
      return
    rescue Exception => e
      logger.info "#{caller_info} Unexpected exception processing #{contents_filename}:"
      logger.info "#{e.class}: #{e.message}"
      logger.info e.backtrace.join("\n")
      redirect_to :back, :alert => "An unexpected error has prevented processing that file"
      return
    end

    basename = File.basename(contents_filename)
    zip_filename = create_zip(session[:daisy_file], basename, xml)    
    send_file zip_filename, :type => 'application/zip; charset=utf-8', :filename => basename + '.zip', :disposition => 'attachment' 
  end

  def get_xml_with_descriptions
    book_directory = session[:daisy_directory]
    contents_filename = get_daisy_contents_xml_name(book_directory)
    xml_file = File.read(contents_filename)
    begin
      xml = get_contents_with_updated_descriptions(xml_file)
    rescue UnrecognizedProdnoteException
      logger.info "#{caller_info} Unrecognized prodnote elements in #{contents_filename}"
      redirect_to :back, :alert => "Unable to update descriptions because the uploaded book contained descriptions from other sources"
      return
    rescue NonDaisyXMLException => e
      logger.info "#{caller_info} Uploaded non-dtbook #{contents_filename}"
      redirect_to :back, :alert => "Uploaded file must be a valid Daisy book XML content file"
      return
    rescue MissingBookUIDException => e
      logger.info "#{caller_info} Uploaded dtbook without UID #{contents_filename}"
      redirect_to :back, :alert => "Uploaded Daisy book XML content file must have a UID element"
      return
    rescue Nokogiri::XML::XPath::SyntaxError => e
      logger.info "#{caller_info} Uploaded invalid XML file #{contents_filename}"
      logger.info "#{e.class}: #{e.message}"
      logger.info "Line #{e.line}, Column #{e.column}, Code #{e.code}"
      redirect_to :back, :alert => "Uploaded file must be a valid Daisy book XML content file"
      return
    rescue Exception => e
      logger.info "#{caller_info} Unexpected exception processing #{contents_filename}:"
      logger.info "#{e.class}: #{e.message}"
      logger.info e.backtrace.join("\n")
      redirect_to :back, :alert => "An unexpected error has prevented processing that file"
      return
    end
    
    send_data xml, :type => 'application/xml; charset=utf-8', :filename => contents_filename, :disposition => 'attachment' 
  end
  
  def submit
    book = params[:book]
    if !book
      flash[:alert] = "Must specify a book file to process"
      redirect_to :action => 'upload'
      return
    end
    
    file = File.new( book.path )
    if !valid_daisy_zip?(file)
      flash[:alert] = "Uploaded file must be a valid Daisy (zip) file"
      redirect_to :action => 'upload'
      return
    end
    
    book_directory = unzip_to_temp(file)
    session[:daisy_directory] = book_directory

    copy_of_daisy_file = File.join(book_directory, "Daisy.zip")
    FileUtils.cp(book.path, copy_of_daisy_file)
    session[:daisy_file] = copy_of_daisy_file

    redirect_to :action => 'edit'
  end

  def edit
    render :layout => 'frames'
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
  
  def image
    image_name = params[:image]
    book_directory = session[:daisy_directory]
    images_directory = File.join(book_directory, 'images')
    image_file = File.join(images_directory, image_name)
    contents = File.read(image_file)
    render :text => contents, :content_type => 'image/jpeg'
  end

  def side_bar
    book_directory = session[:daisy_directory]
    contents_filename = get_daisy_contents_xml_name(book_directory)
    xml = File.read(contents_filename)
    doc = Nokogiri::XML xml

    @images = []
    images = doc.xpath( doc, "//xmlns:img")
    images.each do | image_node |
      @images << image_node['src']
    end
  end
  
    
private
  def valid_daisy_zip?(file)
    begin
      Zip::ZipFile.open(file) do |zipfile|
        zipfile.get_entry 'dtbook-2005-3.dtd'
      end
    rescue
      return false
    end
    
    return true
  end
  
  def unzip_to_temp(zipped_file)
    dir = Dir.mktmpdir
    Zip::ZipFile.foreach(zipped_file) do | entry |
      entry.extract(File.join(dir, entry.name))
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
      
      dynamic_description = dynamic_image.best_description
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
    puts "create_zip #{old_daisy_zip}, #{contents_filename}, size=#{new_xml_contents.size}"
    new_contents_file = Tempfile.new('baked-xml')
    new_contents_file.write(new_xml_contents)
    new_contents_file.close
    puts "baked xml: #{new_contents_file.path} size=#{File.size(new_contents_file.path)}"
    new_daisy_zip = Tempfile.new('baked-daisy')
    new_daisy_zip.close
    FileUtils.cp(old_daisy_zip, new_daisy_zip.path)
    puts "copied daisy zip to #{new_daisy_zip.path}"
    Zip::ZipFile.open(new_daisy_zip.path) do |zipfile|
        zipfile.replace(contents_filename, new_contents_file.path)
    end
    return new_daisy_zip.path
  end
end