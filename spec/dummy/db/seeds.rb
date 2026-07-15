# frozen_string_literal: true

# Rich seed data for testing Maglev RAG capabilities
# These seeds are designed to enable queries that require semantic understanding
# and cannot be answered with simple SQL queries.

require "stringio"

puts "Seeding database..."

# The dummy seed task is intentionally destructive so contributors can rebuild
# the same diagnostic graph repeatedly without accumulating duplicate records.
seed_models = [
  Maglev::Chunk,
  ActiveStorage::Attachment,
  ActiveStorage::VariantRecord,
  ActionText::RichText,
  Comment,
  Review,
  OrderItem,
  Order,
  Inventory,
  ProductVariant,
  ProductCategory,
  Tagging,
  CustomerTag,
  CustomerProfile,
  Product,
  Category,
  Tag,
  Customer,
  ActiveStorage::Blob
]
seed_models.each(&:delete_all)
seed_models.each do |model|
  ActiveRecord::Base.connection.reset_pk_sequence!(model.table_name) if model.primary_key
end

seeded_at = Time.zone.parse("2026-07-01 12:00:00")

# =============================================================================
# Categories
# =============================================================================
electronics = Category.create!(
  name: "Electronics",
  description: "Computers, smartphones, and electronic gadgets for tech enthusiasts and professionals"
)
clothing = Category.create!(
  name: "Clothing",
  description: "Apparel, accessories, and fashion items for all seasons"
)
home = Category.create!(
  name: "Home & Kitchen",
  description: "Furniture, appliances, and home improvement products"
)

# =============================================================================
# Tags
# =============================================================================
sale = Tag.create!(name: "Sale")
new_arrival = Tag.create!(name: "New Arrival")
popular = Tag.create!(name: "Popular")
premium = Tag.create!(name: "Premium")
budget = Tag.create!(name: "Budget-Friendly")

# =============================================================================
# Products (with detailed descriptions for semantic search)
# =============================================================================

# --- Electronics ---
laptop = Product.create!(
  name: "ProBook X1 Carbon",
  sku: "ELEC-001",
  price: 1299.99,
  status: "active"
)
laptop.description = "The ProBook X1 Carbon is our flagship ultrabook designed for professionals who demand performance without compromising portability. Featuring a 14-inch 2K IPS display with 100% sRGB color accuracy, Intel Core i7 processor, 16GB LPDDR5 RAM, and 512GB NVMe SSD. The carbon fiber chassis weighs just 1.2kg, making it perfect for commuters and frequent travelers. Battery life reaches up to 8 hours with mixed usage. The backlit keyboard provides excellent tactile feedback for extended typing sessions."
laptop.images.attach(io: StringIO.new("Fake laptop front image"), filename: "x1_front.jpg", content_type: "image/jpeg")
laptop.images.attach(io: StringIO.new("Fake laptop side image"), filename: "x1_side.jpg", content_type: "image/jpeg")
laptop.images.attach(io: StringIO.new("Fake laptop keyboard image"), filename: "x1_keyboard.jpg", content_type: "image/jpeg")
laptop.save!

headphones = Product.create!(
  name: "SoundMax Pro ANC",
  sku: "ELEC-002",
  price: 249.99,
  status: "active"
)
headphones.description = "Premium wireless headphones with advanced Active Noise Cancellation technology. 40mm custom drivers deliver rich, immersive sound with deep bass and crystal-clear highs. Features include Bluetooth 5.3, 30-hour battery life, quick charge (10 minutes for 3 hours playback), and multipoint connection for switching between devices. The memory foam ear cups provide comfort for all-day wear. Foldable design with premium carrying case included."
headphones.images.attach(io: StringIO.new("Fake headphones image"), filename: "headphones.jpg", content_type: "image/jpeg")
headphones.save!

phone = Product.create!(
  name: "Galaxy Ultra S25",
  sku: "ELEC-003",
  price: 1099.99,
  status: "active"
)
phone.description = "Flagship smartphone with 6.8-inch Dynamic AMOLED 2X display, 120Hz adaptive refresh rate, and 2500 nits peak brightness. Quad camera system: 200MP main sensor, 50MP periscope telephoto (5x optical zoom), 12MP ultrawide, and 10MP macro. Powered by Snapdragon 8 Gen 4 with 12GB RAM. 5000mAh battery supports 65W wired and 15W wireless charging. S Pen included for note-taking and creative work. IP68 water resistance."
phone.images.attach(io: StringIO.new("Fake phone image"), filename: "phone.jpg", content_type: "image/jpeg")
phone.save!

# --- Clothing ---
shirt = Product.create!(
  name: "Oxford Classic Shirt",
  sku: "CLTH-001",
  price: 59.99,
  status: "active"
)
shirt.description = "Timeless Oxford cotton shirt perfect for both casual and business settings. Made from 100% long-staple Egyptian cotton with a soft, breathable weave. Features a classic button-down collar, single chest pocket, and adjustable barrel cuffs. Available in 8 colors: White, Light Blue, Pink, Lavender, Sage, Navy, Charcoal, and Burgundy. Machine washable for easy care. Slightly tailored fit for a modern silhouette without being too tight."
shirt.images.attach(io: StringIO.new("Fake shirt front image"), filename: "shirt_front.jpg", content_type: "image/jpeg")
shirt.images.attach(io: StringIO.new("Fake shirt detail image"), filename: "shirt_detail.jpg", content_type: "image/jpeg")
shirt.save!

jacket = Product.create!(
  name: "WeatherGuard Softshell",
  sku: "CLTH-002",
  price: 189.99,
  status: "active"
)
jacket.description = "Versatile softshell jacket designed for unpredictable weather conditions. Features a waterproof membrane with 10,000mm water column rating while maintaining breathability. Three-layer construction: durable outer shell, waterproof-breathable membrane, and brushed fleece interior for warmth. Adjustable hood, zippered hand pockets, and internal media pocket. Reflective elements for visibility in low light. Ideal for commuting, hiking, and everyday wear."
jacket.images.attach(io: StringIO.new("Fake jacket image"), filename: "jacket.jpg", content_type: "image/jpeg")
jacket.save!

# --- Home & Kitchen ---
coffee_maker = Product.create!(
  name: "BrewMaster Elite",
  sku: "HOME-001",
  price: 199.99,
  status: "active"
)
coffee_maker.description = "Professional-grade drip coffee maker for the home barista. 12-cup capacity with precision temperature control (195-205°F optimal extraction range). Built-in conical burr grinder with 5 grind settings from fine to coarse. Programmable 24-hour timer, adjustable brew strength, and automatic keep-warm function. Stainless steel thermal carafe maintains temperature for up to 2 hours. Removable water reservoir for easy filling and cleaning."
coffee_maker.images.attach(io: StringIO.new("Fake coffee maker image"), filename: "coffee.jpg", content_type: "image/jpeg")
coffee_maker.save!

# =============================================================================
# Product-Category relationships
# =============================================================================
ProductCategory.create!(product: laptop, category: electronics)
ProductCategory.create!(product: headphones, category: electronics)
ProductCategory.create!(product: phone, category: electronics)
ProductCategory.create!(product: shirt, category: clothing)
ProductCategory.create!(product: jacket, category: clothing)
ProductCategory.create!(product: coffee_maker, category: home)

# =============================================================================
# Product-Tag relationships
# =============================================================================
Tagging.create!(taggable: laptop, tag: premium)
Tagging.create!(taggable: laptop, tag: popular)
Tagging.create!(taggable: headphones, tag: popular)
Tagging.create!(taggable: phone, tag: premium)
Tagging.create!(taggable: phone, tag: new_arrival)
Tagging.create!(taggable: shirt, tag: sale)
Tagging.create!(taggable: shirt, tag: budget)
Tagging.create!(taggable: jacket, tag: new_arrival)
Tagging.create!(taggable: coffee_maker, tag: popular)

# =============================================================================
# Product Variants
# =============================================================================
laptop_sg = ProductVariant.create!(product: laptop, name: "Space Gray", sku: "ELEC-001-SG", price: 1299.99)
laptop_s = ProductVariant.create!(product: laptop, name: "Silver", sku: "ELEC-001-S", price: 1299.99)
headphones_b = ProductVariant.create!(product: headphones, name: "Midnight Black", sku: "ELEC-002-B", price: 249.99)
headphones_w = ProductVariant.create!(product: headphones, name: "Pearl White", sku: "ELEC-002-W", price: 249.99)
phone_bl = ProductVariant.create!(product: phone, name: "Phantom Blue", sku: "ELEC-003-BL", price: 1099.99)
phone_bk = ProductVariant.create!(product: phone, name: "Carbon Black", sku: "ELEC-003-BK", price: 1099.99)
shirt_b = ProductVariant.create!(product: shirt, name: "White - M", sku: "CLTH-001-WM", price: 59.99)
shirt_b2 = ProductVariant.create!(product: shirt, name: "Light Blue - L", sku: "CLTH-001-BL", price: 59.99)
jacket_g = ProductVariant.create!(product: jacket, name: "Charcoal - M", sku: "CLTH-002-CM", price: 189.99)
coffee_s = ProductVariant.create!(product: coffee_maker, name: "Stainless Steel", sku: "HOME-001-SS", price: 199.99)

# =============================================================================
# Inventories
# =============================================================================
Inventory.create!(product_variant: laptop_sg, quantity: 45, warehouse: "West Coast")
Inventory.create!(product_variant: laptop_s, quantity: 32, warehouse: "West Coast")
Inventory.create!(product_variant: headphones_b, quantity: 120, warehouse: "East Coast")
Inventory.create!(product_variant: headphones_w, quantity: 85, warehouse: "East Coast")
Inventory.create!(product_variant: phone_bl, quantity: 60, warehouse: "Central")
Inventory.create!(product_variant: phone_bk, quantity: 55, warehouse: "Central")
Inventory.create!(product_variant: shirt_b, quantity: 200, warehouse: "East Coast")
Inventory.create!(product_variant: shirt_b2, quantity: 180, warehouse: "East Coast")
Inventory.create!(product_variant: jacket_g, quantity: 75, warehouse: "West Coast")
Inventory.create!(product_variant: coffee_s, quantity: 90, warehouse: "Central")

# =============================================================================
# Customers (diverse profiles for semantic queries)
# =============================================================================

alice = Customer.create!(name: "Alice Chen", email: "alice.chen@example.com")
alice.avatar.attach(io: StringIO.new("Fake avatar"), filename: "alice.jpg", content_type: "image/jpeg")

bob = Customer.create!(name: "Bob Martinez", email: "bob.martinez@example.com")
bob.avatar.attach(io: StringIO.new("Fake avatar"), filename: "bob.jpg", content_type: "image/jpeg")

carol = Customer.create!(name: "Carol Williams", email: "carol.w@example.com")
carol.avatar.attach(io: StringIO.new("Fake avatar"), filename: "carol.jpg", content_type: "image/jpeg")

dave = Customer.create!(name: "Dave Thompson", email: "dave.t@example.com")
dave.avatar.attach(io: StringIO.new("Fake avatar"), filename: "dave.jpg", content_type: "image/jpeg")

eve = Customer.create!(name: "Eve Nakamura", email: "eve.n@example.com")
eve.avatar.attach(io: StringIO.new("Fake avatar"), filename: "eve.jpg", content_type: "image/jpeg")

# =============================================================================
# Customer Profiles (1:1) - with diverse backgrounds
# =============================================================================
CustomerProfile.create!(
  customer: alice,
  bio: "Software engineer at a startup. Works long hours and values productivity tools. Prefers premium products but watches for quality issues. Active reviewer who provides detailed feedback.",
  location: "San Francisco, CA"
)
CustomerProfile.create!(
  customer: bob,
  bio: "Freelance graphic designer. Price-conscious but willing to invest in durable goods. Frequently travels for client meetings. Has strong opinions about product design and ergonomics.",
  location: "Austin, TX"
)
CustomerProfile.create!(
  customer: carol,
  bio: "Remote worker and hobbyist baker. Values comfort and functionality over style. Tends to keep products for years before replacing. Prefers companies with good customer service.",
  location: "Portland, OR"
)
CustomerProfile.create!(
  customer: dave,
  bio: "College student studying computer science. Budget-conscious, relies on student discounts. Tech-savvy but sometimes impatient with product issues. Active in online forums.",
  location: "Boston, MA"
)
CustomerProfile.create!(
  customer: eve,
  bio: "Marketing manager who hosts frequent meetings. Values professional appearance and reliability. Willing to pay premium for products that impress clients. Brand loyal.",
  location: "New York, NY"
)

# =============================================================================
# Customer-Tag relationships
# =============================================================================
CustomerTag.create!(customer: alice, tag: popular)
CustomerTag.create!(customer: alice, tag: premium)
CustomerTag.create!(customer: bob, tag: budget)
CustomerTag.create!(customer: carol, tag: budget)
CustomerTag.create!(customer: dave, tag: budget)
CustomerTag.create!(customer: eve, tag: premium)

# =============================================================================
# Orders (various patterns for behavioral analysis)
# =============================================================================

# Alice - frequent buyer, recent large purchase
order1 = Order.create!(customer: alice, status: "completed", total: 1299.99, placed_at: seeded_at - 3.days)
order2 = Order.create!(customer: alice, status: "completed", total: 249.99, placed_at: seeded_at - 2.weeks)
order3 = Order.create!(customer: alice, status: "completed", total: 59.99, placed_at: seeded_at - 1.month)

# Bob - sporadic buyer, pending order
order4 = Order.create!(customer: bob, status: "pending", total: 249.99, placed_at: seeded_at - 1.day)
order5 = Order.create!(customer: bob, status: "completed", total: 189.99, placed_at: seeded_at - 2.months)

# Carol - single purchase, long time ago
order6 = Order.create!(customer: carol, status: "completed", total: 199.99, placed_at: seeded_at - 3.months)

# Dave - recent first purchase
order7 = Order.create!(customer: dave, status: "completed", total: 1099.99, placed_at: seeded_at - 1.week)

# Eve - multiple recent orders
order8 = Order.create!(customer: eve, status: "completed", total: 1099.99, placed_at: seeded_at - 2.days)
order9 = Order.create!(customer: eve, status: "completed", total: 59.99, placed_at: seeded_at - 5.days)
order10 = Order.create!(customer: eve, status: "shipped", total: 189.99, placed_at: seeded_at - 3.days)

# =============================================================================
# Order Items
# =============================================================================
OrderItem.create!(order: order1, product: laptop, product_variant: laptop_sg, quantity: 1, unit_price: 1299.99)
OrderItem.create!(order: order2, product: headphones, product_variant: headphones_b, quantity: 1, unit_price: 249.99)
OrderItem.create!(order: order3, product: shirt, product_variant: shirt_b, quantity: 1, unit_price: 59.99)
OrderItem.create!(order: order4, product: headphones, product_variant: headphones_w, quantity: 1, unit_price: 249.99)
OrderItem.create!(order: order5, product: jacket, product_variant: jacket_g, quantity: 1, unit_price: 189.99)
OrderItem.create!(order: order6, product: coffee_maker, product_variant: coffee_s, quantity: 1, unit_price: 199.99)
OrderItem.create!(order: order7, product: phone, product_variant: phone_bl, quantity: 1, unit_price: 1099.99)
OrderItem.create!(order: order8, product: phone, product_variant: phone_bk, quantity: 1, unit_price: 1099.99)
OrderItem.create!(order: order9, product: shirt, product_variant: shirt_b2, quantity: 1, unit_price: 59.99)
OrderItem.create!(order: order10, product: jacket, product_variant: jacket_g, quantity: 1, unit_price: 189.99)

# =============================================================================
# Reviews (nuanced feedback for semantic analysis)
# =============================================================================

# Alice's reviews - detailed, balanced feedback
Review.create!(
  customer: alice,
  product: laptop,
  rating: 4,
  title: "Great laptop with minor quirks",
  body: "I've been using the ProBook X1 Carbon for three weeks now for software development work. The keyboard is outstanding for long coding sessions, and the 2K display makes text crisp and easy on the eyes. However, I've noticed the fan gets quite loud during heavy compilation tasks, which can be distracting in quiet offices. The trackpad occasionally loses responsiveness for a split second, though it resolves quickly. Battery life is closer to 6 hours with my workload, not the advertised 8 hours. Overall, solid machine for developers, but temper expectations on battery and noise levels."
)

Review.create!(
  customer: alice,
  product: headphones,
  rating: 5,
  title: "Perfect for focus work",
  body: "These headphones have transformed my productivity. The noise cancellation blocks out my noisy coffee shop visits completely. Sound quality is excellent for both music and video calls. The multipoint connection is seamless between my laptop and phone. Comfortable enough for 8+ hour work sessions. Only minor complaint: the carrying case is bulky compared to competitors."
)

# Bob's reviews - design-focused, sometimes critical
Review.create!(
  customer: bob,
  product: jacket,
  rating: 3,
  title: "Good function, questionable design choices",
  body: "The weather protection is genuinely excellent - kept me dry in heavy Portland rain. However, the fit is too boxy for a $190 jacket. I expected a more tailored silhouette. The zipper pulls feel cheap and one already started fraying after two weeks. Pocket placement is awkward for someone my height (6'2\"). The color is also more olive than the charcoal shown in photos. Functionally solid, but needs design refinement at this price point."
)

# Carol's review - long-term perspective
Review.create!(
  customer: carol,
  product: coffee_maker,
  rating: 4,
  title: "Reliable daily workhorse",
  body: "I've had this coffee maker for 6 months now. It makes consistently good coffee, and the grinder is a nice bonus for freshness. The thermal carafe works as advertised - coffee stays hot for hours. Programming the timer was intuitive. Only gripe: the water reservoir is awkward to clean, and mineral buildup requires frequent descaling. Good value for the price if you want grinder + brewer in one unit."
)

# Dave's reviews - enthusiastic but mentions issues
Review.create!(
  customer: dave,
  product: phone,
  rating: 4,
  title: "Amazing camera, software needs polish",
  body: "The camera system is incredible for the price. Night mode photos rival phones costing twice as much. S Pen is surprisingly useful for taking notes in lectures. However, I've experienced occasional app crashes, especially with multitasking. The phone also gets warm during gaming sessions. Battery drain is noticeable when using 5G. Hardware is 5 stars, software brings it down. Hoping updates fix this."
)

# Eve's reviews - professional perspective
Review.create!(
  customer: eve,
  product: phone,
  rating: 5,
  title: "Perfect for client presentations",
  body: "This phone has impressed multiple clients during presentations. The display quality is stunning for showing design mockups. S Pen annotations during meetings are a game-changer for collaboration. Build quality feels premium and professional. Camera takes excellent headshots for LinkedIn. Only wish it came with more S Pen tips."
)

Review.create!(
  customer: eve,
  product: shirt,
  rating: 4,
  title: "Wardrobe staple",
  body: "Bought this for casual Friday meetings. The fit is flattering and the fabric feels more expensive than the price suggests. Washes well without shrinking. The white is slightly translucent - need an undershirt. Otherwise, excellent value for a professional wardrobe. Already ordered two more colors."
)

# =============================================================================
# Comments (support questions, complaints, discussions)
# =============================================================================

# Product questions
Comment.create!(
  customer: dave,
  body: "Does the ProBook X1 Carbon support dual external monitors? I need this for my development setup with a portable dock. Also, is the RAM user-upgradable or soldered?",
  commentable: laptop
)

Comment.create!(
  customer: bob,
  body: "How does the noise cancellation compare to Sony WH-1000XM5? I work in a co-working space and need maximum isolation. Also concerned about call quality - any issues with microphone pickup?",
  commentable: headphones
)

Comment.create!(
  customer: carol,
  body: "What type of coffee pods does this accept? I have a collection of specialty roasters I'd like to use. Is it compatible with third-party reusable filters?",
  commentable: coffee_maker
)

# Support issues
Comment.create!(
  customer: bob,
  body: "My jacket zipper started separating after just two weeks of normal use. I'm disappointed for a product at this price point. Is this covered under warranty? I have my receipt. The zipper is on the left side, about halfway up when it catches.",
  commentable: jacket
)

Comment.create!(
  customer: alice,
  body: "The trackpad responsiveness issue I mentioned in my review is getting worse. Sometimes I have to tap multiple times to register a click. Firmware is updated to latest. Anyone else experiencing this?",
  commentable: laptop
)

# Feature requests and discussions
Comment.create!(
  customer: dave,
  body: "Would love to see a student discount program. I'm a CS major and need reliable tech for coursework but can't afford full price. Even 15-20% off would help. Any plans for this?",
  commentable: laptop
)

Comment.create!(
  customer: carol,
  body: "The coffee maker works great, but I wish the water reservoir was easier to remove for cleaning. It's a bit awkward to maneuver around the grinder mechanism. Any tips from other owners?",
  commentable: coffee_maker
)

Comment.create!(
  customer: eve,
  body: "For those considering this phone for business: the S Pen latency is noticeably improved over previous generations. I use it daily for signing PDFs and annotating client decks. Highly recommend for professionals who need quick note-taking.",
  commentable: phone
)

# =============================================================================
# Summary
# =============================================================================
puts "\nSeed data created successfully!"
puts "=" * 60
puts "  Categories:          #{Category.count}"
puts "  Tags:                #{Tag.count}"
puts "  Products:            #{Product.count}"
puts "  Product Variants:    #{ProductVariant.count}"
puts "  Inventories:         #{Inventory.count}"
puts "  Customers:           #{Customer.count}"
puts "  Customer Profiles:   #{CustomerProfile.count}"
puts "  Orders:              #{Order.count}"
puts "  Order Items:         #{OrderItem.count}"
puts "  Reviews:             #{Review.count}"
puts "  Comments:            #{Comment.count}"
puts "  Product Categories:  #{ProductCategory.count}"
puts "  Taggings:            #{Tagging.count}"
puts "  Customer Tags:       #{CustomerTag.count}"
puts "=" * 60

# =============================================================================
# Note: Indexing happens automatically via after_commit callbacks
# The dummy test queue records jobs without calling a live provider
# =============================================================================
puts "\nReindex explicitly with `bin/rails maglev:reindex_all` when needed."
puts "Current chunks: #{Maglev::Chunk.count}"
