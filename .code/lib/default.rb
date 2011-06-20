# All files in the 'lib' directory will be loaded
# before nanoc starts compiling.

require 'nokogiri'
require 'time'

# Monkey-patch Nanoc! :D

class Nanoc3::Filters::ColorizeSyntax
  def run(content, params = {})
    # Take colorizers from parameters
    @colorizers = Hash.new(DEFAULT_COLORIZER)
    @colorizers.merge! params[:colorizers] || {}

    # Colorize
    doc = Nokogiri::HTML.fragment(content)
    doc.css('pre').each do |element|
      next unless element['class'] || element['class'] == "term"

      code = element.children.first

      # Highlight
      highlighted_code = highlight(code.inner_text, element['class'], params)
      code.inner_html = highlighted_code
    end

    doc.to_html(:encoding => 'UTF-8')
  end
end

include Nanoc3::Helpers::HTMLEscape
include Nanoc3::Helpers::LinkTo

class Post
  @all = nil

  class << self
    def all(items)
      @all = items.select { |i|
        i.identifier =~ %r{^/posts/}
      }.map { |item| new(item) }.sort do |a, b|
        b.creation_time <=> a.creation_time
      end
    end

    def of(item)
      new(item) if item.identifier =~ %r{^/posts/}
    end
  end

  def initialize(item)
    @item = item
  end

  def url
    @item.reps.first.path
  end

  def link
    link_to title, @item
  end

  def title
    @item[:title]
  end

  def date
    creation_time.strftime "%A %d %B %Y"
  end

  def creation_time
    @time ||= Time.parse(@item[:now])
  end
end
