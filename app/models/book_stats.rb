class BookStats < ActiveRecord::Base
  belongs_to :book
  
  def self.create_book_row (book)
    book_stats = BookStats.where(:book_id => book.id).first

    if !(book_stats)
      book_stats = BookStats.new :book_id => book.id
    end
    book_stats.total_images = DynamicDescription.connection.select_value("select count(id) from dynamic_images where book_id = '#{book.id}'")
    book_stats.total_essential_images = DynamicImage.connection.select_value("select count(id) from dynamic_images where book_id = '#{book.id}' and should_be_described = true")
    book_stats.total_images_described = DynamicDescription.connection.select_value("select count(distinct(dynamic_image_id)) from dynamic_descriptions where book_id = '#{book.id}'")
    book_stats.essential_images_described = DynamicDescription.connection.select_value("SELECT count(id) FROM dynamic_images di,
    (select dynamic_image_id from dynamic_descriptions where dynamic_descriptions.book_id = '#{book.id}' and is_current = 1) as essential
    WHERE book_id = '#{book.id}' and should_be_described = true and di.id = essential.dynamic_image_id ;")

    book_stats.save!
  end
end